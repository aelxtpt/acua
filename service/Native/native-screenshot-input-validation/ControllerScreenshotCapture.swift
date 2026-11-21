import Foundation
import CoreGraphics

enum ControllerScreenshotCaptureError: Error, Equatable, Sendable {
    case invalidCaptureSize(CGSize)
    case screenCaptureFailed
}

enum ControllerScreenshotContentScope: Equatable, Sendable {
    case currentProcess, all, onScreenExcludingDesktop
}

struct ControllerScreenshotCaptureOptions: Sendable {
    var appName: String? = nil
    var delaySeconds: Int? = nil
    var imageSize: CGSize? = nil
    var includedWindowIDs: [UInt32]? = nil
    var cropToFirstWindow = false
    var shouldBeOpaque = true
    var includeWindowShadow = false
}

/// The native implementation reads immutable framework objects through these
/// accessors. Separate reads deliberately remain separate, including repeated
/// content.windows/content.displays accesses after the selected-window lookup.
protocol ControllerScreenshotCaptureBackend: Sendable {
    associatedtype Content: Sendable
    associatedtype Window: Sendable
    associatedtype Display: Sendable
    associatedtype Filter: Sendable
    associatedtype Configuration: Sendable
    associatedtype Image: Sendable
    var currentProcessContentAvailable: Bool { get }
    @MainActor func ownVisibleWindowIDs() -> [UInt32]
    func onScreenWindowIDs() -> [UInt32]
    func sleep(seconds: Int) async throws
    func content(_ scope: ControllerScreenshotContentScope) async throws -> Content
    func windows(_ content: Content) -> [Window]
    func displays(_ content: Content) -> [Display]
    func id(_ window: Window) -> UInt32
    func isOnScreen(_ window: Window) -> Bool
    func frame(_ window: Window) -> CGRect
    func applicationName(_ window: Window) -> String?
    func title(_ window: Window) -> String?
    func frame(_ display: Display) -> CGRect
    func pixelSize(_ display: Display) -> CGSize
    func filter(window: Window) -> Filter
    func filter(display: Display, including windows: [Window]) -> Filter
    func filter(display: Display, excluding windows: [Window]) -> Filter
    func pointPixelScale(_ filter: Filter) -> CGFloat
    func configuration(opaque: Bool, includeWindowShadow: Bool) -> Configuration
    func setSize(_ configuration: Configuration, width: Int, height: Int)
    func setSourceRect(_ configuration: Configuration, _ rect: CGRect)
    func capture(_ filter: Filter, configuration: Configuration) async throws -> Image
    func captureWithSkyLight(windowIDs: [UInt32], rect: CGRect) -> Image?
    func resize(_ image: Image, to size: CGSize) -> Image?
    func invalidSize(_ size: CGSize)
}

struct ControllerScreenshotCapture<Backend: ControllerScreenshotCaptureBackend>: Sendable {
    let backend: Backend
    private struct NamedWindow {
        let id: UInt32
        let appName: String
        let title: String?
    }

    /// All requested IDs must belong to visible NSApp windows
    /// before currentProcess is selected. Nil and an empty array are distinct.
    func contentScope(includedIDs: [UInt32]?) async -> ControllerScreenshotContentScope {
        if let includedIDs {
            let own = Set(await backend.ownVisibleWindowIDs())
            if includedIDs.allSatisfy(own.contains) {
                return backend.currentProcessContentAvailable ? .currentProcess : .all
            }
            let visible = backend.onScreenWindowIDs()
            return includedIDs.allSatisfy(visible.contains) ? .onScreenExcludingDesktop : .all
        }
        return .onScreenExcludingDesktop
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize names, then three ordered first-match passes:
    /// exact, prefix, and (only for queries of at least four Characters) contains.
    /// The selected ID is looked up again in a fresh content.windows array.
    private func matchingWindow(in content: Backend.Content, appName: String) -> Backend.Window? {
        let visible = backend.windows(content).filter(backend.isOnScreen)
        let candidates: [NamedWindow] = visible.compactMap { window in
            guard let name = backend.applicationName(window) else { return nil }
            let normalized = Self.normalized(name)
            guard !normalized.isEmpty else { return nil }
            return .init(id: backend.id(window), appName: normalized, title: backend.title(window))
        }
        let query = Self.normalized(appName)
        let selected = candidates.first { Self.normalized($0.appName) == query }
            ?? candidates.first { Self.normalized($0.appName).hasPrefix(query) }
            ?? (query.count >= 4 ? candidates.first { $0.appName.lowercased().contains(query) } : nil)
        guard let selected else { return nil }
        return backend.windows(content).first { backend.id($0) == selected.id }
    }

    static func pixelSize(_ size: CGSize) -> (width: Int, height: Int)? {
        ScreenshotGeometry.pixelSize(size, offscreen: false)
    }

    func capture(_ options: ControllerScreenshotCaptureOptions) async throws -> Backend.Image {
        if let delay = options.delaySeconds, delay > 0 { try await backend.sleep(seconds: delay) }
        let content = try await backend.content(contentScope(includedIDs: options.includedWindowIDs))
        let single: Backend.Window?
        if let ids = options.includedWindowIDs, ids.count == 1 {
            single = backend.windows(content).first { backend.id($0) == ids[0] }
        } else if options.includedWindowIDs?.isEmpty != false, let appName = options.appName {
            single = matchingWindow(in: content, appName: appName)
        } else { single = nil }

        // Read this window snapshot before either capture path. A
        // duplicate identifier makes the snapshot ambiguous.
        let windows = backend.windows(content)
        var available = [UInt32: Backend.Window](minimumCapacity: windows.count)
        for window in windows {
            guard available.updateValue(window, forKey: backend.id(window)) == nil else {
                throw ControllerScreenshotCaptureError.screenCaptureFailed
            }
        }
        if let single, !backend.isOnScreen(single) {
            return try offscreen(ids: [backend.id(single)], frame: backend.frame(single), imageSize: options.imageSize)
        }
        if let ids = options.includedWindowIDs, options.cropToFirstWindow,
           let firstID = ids.first, let first = available[firstID], !backend.isOnScreen(first) {
            return try offscreen(ids: ids, frame: backend.frame(first), imageSize: options.imageSize)
        }

        let filter: Backend.Filter
        let naturalSize: CGSize
        let sourceRect: CGRect?
        if let single {
            filter = backend.filter(window: single)
            // Ask the frame getter separately for width and height.
            naturalSize = .init(width: backend.frame(single).width, height: backend.frame(single).height)
            sourceRect = nil
        } else if let ids = options.includedWindowIDs {
            let included = ids.compactMap { available[$0] }
            guard let fallback = backend.displays(content).first else { throw ControllerScreenshotCaptureError.screenCaptureFailed }
            let rect: CGRect
            if options.cropToFirstWindow, let first = ids.first.flatMap({ available[$0] }) {
                rect = backend.frame(first)
            } else { rect = included.reduce(CGRect.null) { $0.union(backend.frame($1)) } }
            let displays = backend.displays(content)
            var selected = displays.first ?? fallback
            for candidate in displays.dropFirst() {
                let old = backend.frame(selected).intersection(rect)
                let new = backend.frame(candidate).intersection(rect)
                if old.width * old.height < new.width * new.height { selected = candidate }
            }
            let displayFrame = backend.frame(selected)
            sourceRect = rect.offsetBy(dx: -displayFrame.origin.x, dy: -displayFrame.origin.y)
            filter = backend.filter(display: selected, including: included)
            naturalSize = .init(width: rect.width, height: rect.height)
        } else {
            guard let display = backend.displays(content).first else { throw ControllerScreenshotCaptureError.screenCaptureFailed }
            filter = backend.filter(display: display, excluding: [])
            naturalSize = backend.pixelSize(display)
            sourceRect = nil
        }
        let configuration = backend.configuration(opaque: options.shouldBeOpaque, includeWindowShadow: options.includeWindowShadow)
        let requested: CGSize
        if let imageSize = options.imageSize { requested = imageSize }
        else {
            let scale = backend.pointPixelScale(filter)
            requested = .init(width: naturalSize.width * scale, height: naturalSize.height * scale)
        }
        guard let size = Self.pixelSize(requested) else {
            backend.invalidSize(requested)
            throw ControllerScreenshotCaptureError.invalidCaptureSize(requested)
        }
        backend.setSize(configuration, width: size.width, height: size.height)
        if let sourceRect { backend.setSourceRect(configuration, sourceRect) }
        return try await backend.capture(filter, configuration: configuration)
    }

    private func offscreen(ids: [UInt32], frame: CGRect, imageSize: CGSize?) throws -> Backend.Image {
        guard let image = backend.captureWithSkyLight(windowIDs: ids, rect: frame) else {
            throw ControllerScreenshotCaptureError.screenCaptureFailed
        }
        if let imageSize { return backend.resize(image, to: imageSize) ?? image }
        return image
    }
}
