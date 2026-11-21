import AppKit
import ApplicationServices
import Darwin
import System
import ScreenCaptureKit

enum Capture {
    static let jpegQuality: CGFloat = 0.85
    private static var overrideDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ACUA_SCREENSHOT_DIRECTORY"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static var temporaryDirectory: URL {
        overrideDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("AcuaAppSnapshots", isDirectory: true)
    }
    static func removeTemporaryImage(_ path: String?) {
        guard let path else { return }
        let rawURL = URL(fileURLWithPath: path)
        if NativeAppSnapshotImage.removeIfOwned(rawURL) { return }
        let url = rawURL.standardizedFileURL
        if NativeAppSnapshotImage.removeIfOwned(url) { return }
        let name = url.deletingPathExtension().lastPathComponent
        guard url.deletingLastPathComponent() == temporaryDirectory.standardizedFileURL,
              url.pathExtension == "jpg", name.hasPrefix("app-snapshot-"), UUID(uuidString: String(name.dropFirst(8))) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    struct Captured {
        let path: URL
        let width: Int
        let height: Int
        let geometry: ScreenshotGeometry
        let nativePath:FilePath?
        init(path:URL,width:Int,height:Int,geometry:ScreenshotGeometry,nativePath:FilePath?=nil) {
            self.path=path;self.width=width;self.height=height;self.geometry=geometry;self.nativePath=nativePath
        }
    }

    struct WindowReference {
        let frame: CGRect
        let title: String?
        let windowID: UInt32?
        init(frame: CGRect, title: String?, windowID: UInt32? = nil) {
            self.frame = frame; self.title = title; self.windowID = windowID
        }
    }

    struct NativeGeometryPlan {
        let layout: ScreenshotGeometry.NativeLayout
        let settings: NativeAppSnapshotImage.Settings
    }

    static func nativeGeometryPlan(frame: CGRect) throws -> NativeGeometryPlan {
        let settings = NativeAppSnapshotImage.Settings.current()
        let scale = try RequestRuntime.onMainThread {
            MainActor.assumeIsolated { nativeBackingScale(for: frame) }
        }
        guard let layout = ScreenshotGeometry.nativeLayout(frame: frame, backingScale: scale,
            sizing: screenshotSizing(scale: scale, nativeSettings: settings)) else {
            throw ServiceError(.accessibilityError, "Invalid native screenshot dimensions")
        }
        return NativeGeometryPlan(layout: layout, settings: settings)
    }

    static func nativeWindowTarget(_ window: AXUIElement, appPID: pid_t) throws -> PointerTarget {
        if let id = try? AccessibilityWindowSPI.windowID(window),
           let info = windowDescription(id),
           let candidate = nativeWindowInfo(info) {
            guard candidate.ownerPID == appPID || (try? AccessibilityWindowSPI.actualPID(window)) == candidate.ownerPID else {
                throw ServiceError(.accessibilityError, "Selected accessibility window has a different owner")
            }
            return PointerTarget(windowID: id, ownerPID: candidate.ownerPID, screenFrame: candidate.frame)
        }

        if AX.string(window, kAXRoleAttribute as String) == kAXScrollAreaRole as String,
           NSRunningApplication(processIdentifier: appPID)?.bundleIdentifier == "com.apple.finder" {
            let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            if let desktop = CaptureLayout.finderDesktopWindow(pid: appPID,
                desktopIconLevel: Int(CGWindowLevelForKey(.desktopIconWindow)), windows: entries.compactMap(nativeWindowInfo)) {
                return PointerTarget(windowID: desktop.id, ownerPID: desktop.ownerPID, screenFrame: desktop.frame)
            }
        }

        let frame = AX.rectangle(window, "AXFrame") ?? {
            guard let origin = AX.point(window, kAXPositionAttribute as String),
                  let size = AX.size(window, kAXSizeAttribute as String) else { return nil }
            return CGRect(origin: origin, size: size)
        }()
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let frame, let candidate = CaptureLayout.matchNativeWindow(pid: appPID, frame: frame,
            title: AX.string(window, kAXTitleAttribute as String), windows: entries.compactMap(nativeWindowInfo),
            servicePID: getpid(), menuLevel: Int(CGWindowLevelForKey(.mainMenuWindow))) else {
            throw ServiceError(.accessibilityError, "Could not resolve the selected accessibility window for capture")
        }
        return PointerTarget(windowID: candidate.id, ownerPID: candidate.ownerPID, screenFrame: candidate.frame)
    }

    private static func nativeWindowInfo(_ info: [String: Any]) -> CaptureLayout.NativeWindow? {
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, id != 0,
              let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner > 0,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), CaptureLayout.valid(frame) else { return nil }
        return .init(id: id, ownerPID: owner, frame: frame, title: info[kCGWindowName as String] as? String, layer: layer)
    }

    /// Match the selected AX window, or use the largest window for standalone captures.
    static func captureWindow(pid: pid_t, into directory: URL?, matching reference: WindowReference? = nil,
                              additionalWindowIDs: [UInt32] = [], nativeAppName: String? = nil,
                              nativePlan: NativeGeometryPlan? = nil) throws -> Captured {
        try Permissions.requireUnlockedScreen()
        try Permissions.requireScreenRecording()
        let pending = PendingResult<Captured> { value in discard(value.path) }
        let task = Task {
            pending.complete(await Result {
                try await captureAsync(pid: pid, directory: directory, matching: reference,
                                       additionalWindowIDs: additionalWindowIDs, nativeAppName: nativeAppName, nativePlan: nativePlan)
            })
        }
        do { try RequestRuntime.wait(for: pending.signal, maximumSeconds: 30) }
        catch { pending.abandon(); task.cancel(); throw error }
        return try pending.take()
    }

    private static func discard(_ url: URL) {
        if !NativeAppSnapshotImage.removeIfOwned(url) { try? FileManager.default.removeItem(at: url) }
    }

    static func captureAsync(pid: pid_t, directory: URL?, matching reference: WindowReference?,
                                     additionalWindowIDs: [UInt32], nativeAppName: String?,
                                     nativePlan: NativeGeometryPlan?) async throws -> Captured {
        let includeOffscreen: Bool
        if nativeAppName != nil, let id = reference?.windowID {
            let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let onscreen = Set(entries.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            includeOffscreen = CaptureLayout.needsFullWindowList(requestedIDs: [id] + additionalWindowIDs, onscreenIDs: onscreen)
        } else {
            includeOffscreen = false
        }
        let content = try await (includeOffscreen ? SCShareableContent.current
                                                 : SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
        try Task.checkCancellation()
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && CaptureLayout.valid($0.frame) }
        let window: SCWindow?
        if let reference {
            let matches = candidates.filter {
                (reference.windowID == nil || $0.windowID == reference.windowID) &&
                    ScreenshotGeometry.framesMatch($0.frame, reference.frame)
            }
            let titled = matches.filter { $0.title == reference.title }
            // Ambiguous or unavailable windows must not fall back to a different image.
            window = matches.count == 1 ? matches.first : (titled.count == 1 ? titled.first : nil)
        } else {
            window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        }
        guard let window else {
            throw ServiceError(.accessibilityError, "No capturable window for pid \(pid)")
        }
        let offscreen = includeOffscreen && !window.isOnScreen
        let layout = try CaptureLayout.make(primaryID: window.windowID, additionalIDs: additionalWindowIDs,
            windows: content.windows.map { CaptureLayout.Window(id: $0.windowID, frame: $0.frame) },
            displays: content.displays.map { CaptureLayout.Display(id: $0.displayID, frame: $0.frame) },
            useDisplayForAdditionalWindows: !offscreen)
        let nativeSettings = nativePlan?.settings ?? nativeAppName.map { _ in NativeAppSnapshotImage.Settings.current() }
        var nativeLayout = nativePlan?.layout
        if nativeLayout == nil, let nativeSettings {
            let windowServerFrame = reference?.frame ?? layout.screenFrame
            let scale = await MainActor.run { nativeBackingScale(for: windowServerFrame) }
            try Task.checkCancellation()
            nativeLayout = ScreenshotGeometry.nativeLayout(frame: windowServerFrame, backingScale: scale,
                sizing: screenshotSizing(scale: scale, nativeSettings: nativeSettings))
        }
        let requestedSize = nativeLayout?.requestedSize
        let image: CGImage
        if offscreen {
            let raw = try captureOffscreen(windowIDs: layout.windowIDs, frame: layout.screenFrame)
            image = requestedSize.map { resize(raw, to: $0) } ?? raw
        } else {
            let nativeSize = requestedSize.flatMap { ScreenshotGeometry.pixelSize($0, offscreen: false) }
            if nativeSettings != nil, nativeSize == nil {
                throw ServiceError(.accessibilityError, "Invalid native screenshot dimensions")
            }
            image = try await captureOnscreen(window: window, content: content, layout: layout, nativeSize: nativeSize)
        }
        try Task.checkCancellation()
        // A still-owned offscreen window can supply an image. Pointer routing
        // uses its separate onscreen-only revalidation before sending input.
        guard let current = currentFrame(windowID: window.windowID, pid: pid, requireOnscreen: !offscreen),
              ScreenshotGeometry.framesMatch(current, window.frame) else {
            throw ServiceError(.accessibilityError, "Window changed during capture; request a new app state")
        }
        let url: URL
        var nativePath:FilePath?
        if let nativeAppName, let nativeSettings {
            let file = try NativeAppSnapshotImage.writeFile(image, appName: nativeAppName,
                                               directory: directory ?? overrideDirectory ?? NativeAppSnapshotImage.defaultDirectory,
                                               encoding: nativeSettings.encoding)
            url=file.url;nativePath=file.path
        } else {
            let dir = directory ?? temporaryDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("app-snapshot-\(UUID().uuidString).jpg")
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
                throw ServiceError(.unknownError, "Failed to encode screenshot")
            }
            try data.write(to: url)
        }
        do { try Task.checkCancellation() }
        catch { discard(url); throw error }
        let geometry = ScreenshotGeometry(windowID: window.windowID, ownerPID: pid, screenFrame: layout.screenFrame,
                                          pixelWidth: image.width, pixelHeight: image.height, includedWindowIDs: layout.windowIDs,
                                          nativeLayout: nativeLayout)
        return Captured(path: url, width: image.width, height: image.height, geometry: geometry,nativePath:nativePath)
    }

    private static func screenshotSizing(scale: CGFloat, nativeSettings: NativeAppSnapshotImage.Settings?) -> ScreenshotGeometry.Sizing {
        let overrideSizing = ProcessInfo.processInfo.environment["ACUA_SCREENSHOT_SIZING"].flatMap(ScreenshotGeometry.Sizing.init(rawValue:))
        return overrideSizing ?? nativeSettings?.sizing(backingScale: scale) ?? .points
    }

    @MainActor private static func nativeBackingScale(for frame: CGRect) -> CGFloat {
        // CGWindow.scale (0x1002663D4) compares the WindowServer frame
        // directly with NSScreen frames and defaults to 2 when none exist.
        let screens = NSScreen.screens
        guard let index = CaptureLayout.bestDisplayIndex(for: frame, displayFrames: screens.map(\.frame)) else { return 2 }
        return screens[index].backingScaleFactor
    }

    private static func captureOnscreen(window: SCWindow, content: SCShareableContent, layout: CaptureLayout,
                                        nativeSize: (width: Int, height: Int)?) async throws -> CGImage {
        let filter: SCContentFilter
        if let displayID = layout.displayID {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ServiceError(.accessibilityError, "Capture display disappeared")
            }
            let included = Set(layout.windowIDs)
            filter = SCContentFilter(display: display, including: content.windows.filter { included.contains($0.windowID) })
        } else { filter = SCContentFilter(desktopIndependentWindow: window) }
        let config = SCStreamConfiguration()
        if let source = layout.sourceRect { config.sourceRect = source }
        let size: (width: Int, height: Int)
        if let nativeSize {
            size = nativeSize
        } else {
            let scale = CGFloat(filter.pointPixelScale)
            size = ScreenshotGeometry.imageSize(frame: layout.screenFrame, backingScale: scale,
                                                sizing: screenshotSizing(scale: scale, nativeSettings: nil))
            config.captureResolution = .nominal
            config.ignoreGlobalClipSingleWindow = true
            config.includeChildWindows = true
            config.scalesToFit = true
        }
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreShadowsDisplay = true
        config.shouldBeOpaque = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func captureOffscreen(windowIDs: [UInt32], frame: CGRect) throws -> CGImage {
        // Call the SPI with the ID array and the four CGRect components.
        let connection = ControllerWindowServerOperations.native.mainConnection()
        guard let capture = ControllerWindowServerOperations.native.captureFunction,
              let count = Int32(exactly: windowIDs.count), count > 0 else {
            throw ServiceError(.accessibilityError, "Offscreen window capture is unavailable")
        }
        let result = windowIDs.withUnsafeBufferPointer { ids in
            ids.baseAddress.flatMap { capture(connection, $0, count, 0x800, frame)?.takeUnretainedValue() }
        }
        guard let images = result as? [CGImage], let image = images.first else {
            throw ServiceError(.accessibilityError, "Could not capture the offscreen window")
        }
        return image
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage {
        guard let space = image.colorSpace, size != CGSize(width: image.width, height: image.height),
              let (width, height) = ScreenshotGeometry.pixelSize(size, offscreen: true),
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0, space: space,
                bitmapInfo: image.bitmapInfo.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func windowDescription(_ windowID: CGWindowID) -> [String: Any]? {
        WindowDescription.lookup(windowID)
    }

    static func currentFrame(windowID: CGWindowID, pid: pid_t, requireOnscreen: Bool = true) -> CGRect? {
        guard let info = windowDescription(windowID),
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              !requireOnscreen || (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    static func pointerTarget(pid: pid_t, frame: CGRect, title: String?) throws -> PointerTarget {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = windows.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let current = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return ScreenshotGeometry.framesMatch(frame, current)
        }
        let titled = matches.filter { ($0[kCGWindowName as String] as? String) == title }
        guard let match = matches.count == 1 ? matches.first : (titled.count == 1 ? titled.first : nil),
              let windowID = (match[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
            throw ServiceError(.accessibilityError, "Could not uniquely identify the element's onscreen window")
        }
        return PointerTarget(windowID: windowID, ownerPID: pid, screenFrame: frame)
    }

    static func dataURL(for file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
