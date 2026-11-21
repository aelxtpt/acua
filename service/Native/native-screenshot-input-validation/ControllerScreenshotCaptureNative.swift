import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit

/// ScreenCaptureKit exposes immutable metadata and configuration objects to
/// its asynchronous callbacks. Each capture owns these references separately.
struct ControllerScreenCaptureValue<Value>: @unchecked Sendable { let value: Value }

struct ControllerScreenshotCaptureNative: ControllerScreenshotCaptureBackend {
    typealias Content = ControllerScreenCaptureValue<SCShareableContent>
    typealias Window = ControllerScreenCaptureValue<SCWindow>
    typealias Display = ControllerScreenCaptureValue<SCDisplay>
    typealias Filter = ControllerScreenCaptureValue<SCContentFilter>
    typealias Configuration = ControllerScreenCaptureValue<SCStreamConfiguration>
    typealias Image = CGImage
    let signposter = OSSignposter(subsystem: "local.cua", category: "ScreenshotImplementation")
    var currentProcessContentAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }
    @MainActor func ownVisibleWindowIDs() -> [UInt32] {
        guard let app = NSApp else { preconditionFailure("NSApp is unavailable for screenshot window enumeration") }
        return app.orderedWindows.compactMap { window in
            guard window.windowNumber >= 1, window.isVisible else { return nil }
            return UInt32(window.windowNumber)
        }
    }
    func onScreenWindowIDs() -> [UInt32] {
        ControllerOnScreenWindowIDs.read()
    }
    func sleep(seconds: Int) async throws {
        let interval = signposter.beginInterval("Sleep")
        defer { signposter.endInterval("Sleep", interval) }
        try await ContinuousClock().sleep(for: .seconds(seconds))
    }
    func content(_ scope: ControllerScreenshotContentScope) async throws -> Content {
        let interval = signposter.beginInterval("Get Shareable Content")
        defer { signposter.endInterval("Get Shareable Content", interval) }
        switch scope {
        case .currentProcess:
            if #available(macOS 14.4, *) { return .init(value: try await SCShareableContent.currentProcess) }
            return .init(value: try await SCShareableContent.current)
        case .all: return .init(value: try await SCShareableContent.current)
        case .onScreenExcludingDesktop:
            return .init(value: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
        }
    }
    func windows(_ content: Content) -> [Window] { content.value.windows.map { .init(value: $0) } }
    func displays(_ content: Content) -> [Display] { content.value.displays.map { .init(value: $0) } }
    func id(_ window: Window) -> UInt32 { window.value.windowID }
    func isOnScreen(_ window: Window) -> Bool { window.value.isOnScreen }
    func frame(_ window: Window) -> CGRect { window.value.frame }
    func applicationName(_ window: Window) -> String? { window.value.owningApplication?.applicationName }
    func title(_ window: Window) -> String? { window.value.title }
    func frame(_ display: Display) -> CGRect { display.value.frame }
    func pixelSize(_ display: Display) -> CGSize { .init(width: display.value.width, height: display.value.height) }
    func filter(window: Window) -> Filter { .init(value: SCContentFilter(desktopIndependentWindow: window.value)) }
    func filter(display: Display, including windows: [Window]) -> Filter {
        .init(value: SCContentFilter(display: display.value, including: windows.map(\.value)))
    }
    func filter(display: Display, excluding windows: [Window]) -> Filter {
        .init(value: SCContentFilter(display: display.value, excludingWindows: windows.map(\.value)))
    }
    func pointPixelScale(_ filter: Filter) -> CGFloat { CGFloat(filter.value.pointPixelScale) }
    func configuration(opaque: Bool, includeWindowShadow: Bool) -> Configuration {
        let value = SCStreamConfiguration()
        value.ignoreShadowsSingleWindow = !includeWindowShadow
        value.ignoreShadowsDisplay = true
        value.showsCursor = false
        value.shouldBeOpaque = opaque
        return .init(value: value)
    }
    func setSize(_ configuration: Configuration, width: Int, height: Int) {
        configuration.value.width = width
        configuration.value.height = height
    }
    func setSourceRect(_ configuration: Configuration, _ rect: CGRect) { configuration.value.sourceRect = rect }
    func capture(_ filter: Filter, configuration: Configuration) async throws -> CGImage {
        let interval = signposter.beginInterval("Capture Screenshot")
        defer { signposter.endInterval("Capture Screenshot", interval) }
        return try await SCScreenshotManager.captureImage(contentFilter: filter.value, configuration: configuration.value)
    }
    func captureWithSkyLight(windowIDs: [UInt32], rect: CGRect) -> CGImage? {
        let interval = signposter.beginInterval("Capture Accelerated Window Screenshot")
        defer { signposter.endInterval("Capture Accelerated Window Screenshot", interval) }
        return ControllerScreenshotSkyLight.capture(windowIDs: windowIDs, rect: rect)
    }
    func resize(_ image: CGImage, to size: CGSize) -> CGImage? { ControllerScreenshotImageResize.resize(image, to: size) }
    func invalidSize(_ size: CGSize) {
        Logger(subsystem: "local.cua", category: "ScreenshotImplementation").error("Invalid capture size: \(String(describing: size), privacy: .public)")
    }
}

enum ControllerScreenshotImageResize {
    /// Check the color space and compare the unrounded size before
    /// truncating. If the resize cannot be performed, retain the raw image.
    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let space = image.colorSpace else { return nil }
        if CGFloat(image.width) == size.width, CGFloat(image.height) == size.height { return image }
        guard let pixels = ScreenshotGeometry.pixelSize(size, offscreen: true),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height,
            bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0, space: space,
            bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: .init(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return context.makeImage()
    }
}

enum ControllerScreenshotSkyLight {
    private typealias Connection = @convention(c) () -> OpaquePointer?
    private typealias Images = @convention(c) (OpaquePointer?, UnsafePointer<UInt32>, Int32, UInt32, CGRect) -> Unmanaged<CFArray>?
    private static let connection: Connection = { ControllerWindowServerOperations.native.mainConnection() }
    private static var images: Images? { ControllerWindowServerOperations.native.captureFunction }
    static func capture(windowIDs: [UInt32], rect: CGRect) -> CGImage? {
        let connectionID = connection()
        guard let images, !windowIDs.isEmpty else { return nil }
        let count = Int32(windowIDs.count)
        let value = windowIDs.withUnsafeBufferPointer { ids in
            images(connectionID, ids.baseAddress!, count, 0x800, rect)?.takeUnretainedValue()
        }
        return (value as? [CGImage])?.first
    }
}

enum ControllerNativeScreenshotBuffer {
    static func capture(_ options: ControllerScreenshotCaptureOptions) async throws -> CGImage {
        let backend = ControllerScreenshotCaptureNative()
        let interval = backend.signposter.beginInterval("Capture Screenshot File")
        defer { backend.signposter.endInterval("Capture Screenshot File", interval) }
        return try await ControllerScreenshotCapture(backend: backend).capture(options)
    }
}
