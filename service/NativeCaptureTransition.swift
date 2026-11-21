import AppKit
import ScreenCaptureKit
import ImageIO

/// Appshot's transparent per-screen overlay. All window/layer state belongs to
/// the main thread; workers only wait for movement or capture immutable frames.
final class NativeCaptureTransition {
    private final class Overlay: NSWindow {
        let content = CALayer(), background = CALayer(), container = CALayer(), shutter = CALayer()
        let effects = CALayer(), shadow = CALayer(), image = CALayer(), maskGradient = CAGradientLayer()
        let icon = CALayer(), titleText = CATextLayer()
        var lastLayout: CaptureTransitionGeometry.Layout?
        let display: CaptureTransitionGeometry.Screen
        init(screen: CaptureTransitionGeometry.Screen, title: String?, iconImage: NSImage?, color: NSColor) {
            display = screen
            super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            self.title = "CUA Capture Transition \(UUID())"
            animationBehavior = .none; collectionBehavior = .init(rawValue: 4425)
            backgroundColor = .clear; isOpaque = false; hasShadow = false
            ignoresMouseEvents = true; isReleasedWhenClosed = false; level = .init(rawValue: 25)
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size)); view.wantsLayer = true
            view.layer = CALayer(); contentView = view
            content.frame = view.bounds; view.layer!.addSublayer(content)
            for layer in [content, background, container, shutter, effects, shadow, image, maskGradient, icon, titleText] {
                layer.actions = Dictionary(uniqueKeysWithValues: ["position", "bounds", "contents", "opacity", "cornerRadius", "shadowPath", "shadowOpacity", "colors", "locations", "backgroundColor", "hidden", "mask"].map { ($0, NSNull() as CAAction) })
                layer.contentsScale = screen.scale
            }
            background.isHidden = true; content.addSublayer(background); content.addSublayer(container)
            container.cornerCurve = .circular
            shutter.backgroundColor = NSColor.white.cgColor; shutter.opacity = 0; shutter.masksToBounds = true
            container.addSublayer(shutter); container.addSublayer(effects)
            shadow.shadowColor = NSColor.black.cgColor; shadow.shadowRadius = 5; shadow.shadowOffset = CGSize(width: 0, height: -10)
            effects.addSublayer(shadow); shadow.addSublayer(image)
            image.contentsGravity = .resizeAspect; image.minificationFilter = .trilinear; image.cornerCurve = .circular
            maskGradient.startPoint = CGPoint(x: 0.5, y: 1); maskGradient.endPoint = CGPoint(x: 0.5, y: 0)
            effects.opacity = 0; effects.mask = maskGradient
            icon.contents = iconImage; icon.contentsGravity = .resizeAspect; icon.opacity = 0
            container.addSublayer(icon)
            titleText.string = title; titleText.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            titleText.fontSize = 13; titleText.alignmentMode = .center; titleText.truncationMode = .end
            titleText.isWrapped = false; titleText.foregroundColor = color.cgColor; titleText.opacity = 0
            content.addSublayer(titleText)
        }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        func screenshot(_ value: CGImage) {
            image.contents = value
            let alpha = CALayer(); alpha.frame = shutter.bounds; alpha.contents = value; alpha.contentsGravity = .resizeAspect
            shutter.mask = alpha
        }
        func apply(_ layout: CaptureTransitionGeometry.Layout, style: AppCaptureWire.PresentationStyle,
                   opening: Float, imageOpacity: Float, accessory: Float, final: Bool) {
            lastLayout = layout
            CATransaction.begin(); CATransaction.setDisableActions(true)
            container.frame = layout.container; container.cornerRadius = max(0, layout.cornerRadius)
            effects.frame = CGRect(origin: .zero, size: layout.container.size)
            shadow.frame = layout.image; image.frame = CGRect(origin: .zero, size: layout.image.size)
            image.cornerRadius = max(0, layout.imageCornerRadius); image.masksToBounds = layout.imageCornerRadius > 0
            shadow.shadowOpacity = Float(layout.shadowOpacity)
            shadow.shadowPath = style == .quickChat ? nil : CGPath(roundedRect: image.bounds, cornerWidth: max(0, layout.cornerRadius), cornerHeight: max(0, layout.cornerRadius), transform: nil)
            maskGradient.frame = layout.mask; maskGradient.locations = layout.maskLocations.map { NSNumber(value: Double($0)) }
            maskGradient.colors = layout.maskAlphas.map { NSColor.white.withAlphaComponent($0).cgColor }
            effects.mask = style == .quickChat ? nil : maskGradient
            shutter.frame = layout.image; shutter.cornerRadius = max(0, layout.imageCornerRadius)
            shutter.mask?.frame = shutter.bounds
            shutter.opacity = final ? 0 : opening * (1 - imageOpacity); effects.opacity = imageOpacity
            icon.frame = layout.icon; icon.opacity = accessory; icon.isHidden = icon.contents == nil
            titleText.frame = layout.title ?? .zero; titleText.opacity = accessory; titleText.isHidden = layout.title == nil
            CATransaction.commit()
        }
        var crop: CGRect? {
            guard let layout = lastLayout else { return nil }
            return layout.title.map { layout.container.union($0) } ?? layout.container
        }
        func solidBackground(_ color: NSColor) {
            guard let layout = lastLayout else { return }
            var rect = layout.image.offsetBy(dx: layout.container.minX, dy: layout.container.minY)
            if let title = layout.title { rect = rect.union(title) }
            background.frame = rect; background.backgroundColor = color.cgColor; background.isHidden = false
        }
    }
    private let source: CGRect
    private let destination: CaptureTransitionGeometry.Destination
    private let style: AppCaptureWire.PresentationStyle
    private let title: String?
    private let icon: NSImage?
    private let titleColor, backgroundColor: NSColor
    private let sourceCorner, targetCorner, fontHeight: CGFloat
    private let sourceWindowID: UInt32
    private let fadeDuration: Double
    let metrics: CaptureTransitionGeometry.Metrics
    private var lifecycle = CaptureTransitionLifecycle()
    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var started: TimeInterval = 0
    private var accessoryStarted: TimeInterval?
    private var imageSize: CGSize
    private let movement = DispatchSemaphore(value: 0)
    private var movementSignalled = false
    private var final = false

    private static func main<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
    static func make(sourceFrame: CGRect, windowID: UInt32, windowTitle: String?, app: ResolvedApp,
                     target: AppCaptureWire.AnimationTarget) -> NativeCaptureTransition? {
        main {
            let screens = liveScreens()
            let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let primary = screens.first,
                  let source = CaptureTransitionGeometry.fromCG(sourceFrame, primary: primary.frame),
                  let destination = CaptureTransitionGeometry.destination(target, screens: screens, mainScreenID: mainID),
                  destination.frame.width * destination.screen.scale <= 16_384,
                  destination.frame.height * destination.screen.scale <= 16_384,
                  destination.frame.width * destination.frame.height * destination.screen.scale * destination.screen.scale <= 64_000_000 else { return nil }
            return NativeCaptureTransition(source: source, destination: destination, sourceWindowID: windowID,
                title: CaptureTransitionGeometry.title(window: windowTitle, app: app.running.localizedName, style: target.presentationStyle),
                icon: app.running.icon, appURL: app.running.bundleURL, target: target)
        }
    }
    private static func liveScreens() -> [CaptureTransitionGeometry.Screen] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return .init(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }
    private init?(source: CGRect, destination: CaptureTransitionGeometry.Destination, sourceWindowID: UInt32,
                  title: String?, icon: NSImage?, appURL: URL?, target: AppCaptureWire.AnimationTarget) {
        self.source = source; self.destination = destination; self.sourceWindowID = sourceWindowID
        let requestedFade = (UserDefaults.standard.object(forKey: "appshotMagicMoveFadeDuration") as? NSNumber)?.doubleValue
        fadeDuration = requestedFade.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0.125
        self.style = target.presentationStyle; self.title = title; self.icon = icon
        imageSize = source.size; fontHeight = NSFont.systemFont(ofSize: 13, weight: .medium).boundingRectForFont.height
        // Fallback when the resolvedCornerRadius SPI is unavailable.
        let sdk = appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "DTSDKName") as? String }?.lowercased() ?? ""
        let major = Int(sdk.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)) ?? 0
        sourceCorner = sdk.hasPrefix("macos") && major > 25 ? 30 : 9
        targetCorner = CaptureTransitionGeometry.cornerRadius(target.destinationCornerRadius.map { CGFloat($0) }, frame: destination.frame)
        func color(_ value: AppCaptureWire.Color?, fallback: NSColor) -> NSColor {
            value.map { NSColor(red: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1) } ?? fallback
        }
        titleColor = color(target.destinationPrimaryTextColor, fallback: .labelColor)
        backgroundColor = color(target.destinationBackgroundColor, fallback: NSColor(white: 247.0 / 255, alpha: 1))
        guard let metrics = CaptureTransitionGeometry.metrics(source: source, destination: destination.frame, style: style,
            hasTitle: title != nil, fontHeight: fontHeight, scale: destination.screen.scale) else { return nil }
        self.metrics = metrics
    }
    func start() {
        Self.main {
            guard lifecycle.send(.start) == [.open] else { return }
            overlays = Self.liveScreens().map { Overlay(screen: $0, title: title, iconImage: icon, color: titleColor) }
            started = ProcessInfo.processInfo.systemUptime
            update()
            for overlay in overlays { overlay.order(.above, relativeTo: Int(sourceWindowID)) }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.update() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func act(_ effects: [CaptureTransitionLifecycle.Effect]) {
        for effect in effects {
            if effect == .wakeMoveWaiters, !movementSignalled { movementSignalled = true; movement.signal() }
            if effect == .close {
                timer?.invalidate(); timer = nil
                for overlay in overlays { overlay.orderOut(nil); overlay.close() }
                overlays.removeAll()
            }
        }
    }
    private func update() {
        guard lifecycle.phase != .created && lifecycle.phase != .cancelled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if lifecycle.phase == .opening && elapsed >= 0.15 { act(lifecycle.send(.openingFinished)) }
        let t = max(0, elapsed - 0.15), omega = 2 * Double.pi / metrics.springResponse, damping = metrics.dampingFraction
        let damped = sqrt(1 - damping * damping)
        let progress = final || lifecycle.phase == .arrived ? 1 : lifecycle.phase == .opening ? 0 :
            1 - exp(-damping * omega * t) * (cos(omega * damped * t) + damping / damped * sin(omega * damped * t))
        if progress >= 0.95 && accessoryStarted == nil { accessoryStarted = elapsed }
        let accessory = final ? 1 : accessoryStarted.map { Float(CaptureTransitionGeometry.fade((elapsed - $0) / 0.3)) } ?? 0
        for overlay in overlays {
            guard let layout = CaptureTransitionGeometry.layout(source: source.offsetBy(dx: -overlay.frame.minX, dy: -overlay.frame.minY),
                destination: destination.frame.offsetBy(dx: -overlay.frame.minX, dy: -overlay.frame.minY), imageSize: imageSize,
                progress: progress, initialCornerRadius: sourceCorner, targetCornerRadius: targetCorner,
                style: style, hasTitle: title != nil, fontHeight: fontHeight, scale: overlay.display.scale) else { continue }
            overlay.apply(layout, style: style, opening: Float(CaptureTransitionGeometry.fade(elapsed / 0.15, easeInOut: true)),
                imageOpacity: final ? 1 : lifecycle.phase == .opening ? 0 : fadeDuration == 0 ? 1 : Float(CaptureTransitionGeometry.fade(t / fadeDuration)), accessory: accessory, final: final)
        }
        if lifecycle.phase == .moving && elapsed >= metrics.animationDuration {
            act(lifecycle.send(.moveFinished)); timer?.invalidate(); timer = nil; update()
        }
    }
    func setScreenshot(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ServiceError(.unknownError, "Could not load capture transition image")
        }
        Self.main {
            guard lifecycle.phase != .cancelled else { return }
            imageSize = CGSize(width: image.width, height: image.height)
            for overlay in overlays { overlay.screenshot(image) }; update()
        }
    }
    func waitForMove() throws {
        let finished = Self.main { lifecycle.phase == .arrived }
        if !finished { try RequestRuntime.wait(for: movement, maximumSeconds: 5) }
        guard Self.main({ lifecycle.phase == .arrived }) else { throw ServiceError(.unknownError, "Capture transition cancelled") }
    }
    func complete() { Self.main { act(lifecycle.send(.complete)) } }
    func cancel() { Self.main { act(lifecycle.send(.cancel)) } }
    func solidBackground() { Self.main { if style == .standard { for overlay in overlays { overlay.solidBackground(backgroundColor) } } } }

    private struct Frame {
        let windowID: UInt32
        let bounds: CGRect
        let crop: CGRect
        let scale: CGFloat
    }
    func finalSnapshot() throws -> CaptureFileLease? {
        let frame: Frame? = Self.main {
            guard lifecycle.phase == .arrived else { return nil }
            final = true; update(); CATransaction.flush()
            guard let overlay = overlays.first(where: { $0.frame.contains(CGPoint(x: destination.frame.midX, y: destination.frame.midY)) }) ?? overlays.first,
                  overlay.windowNumber > 0, let crop = overlay.crop else { return nil }
            return Frame(windowID: UInt32(overlay.windowNumber), bounds: overlay.contentView!.bounds, crop: crop, scale: overlay.display.scale)
        }
        guard let frame else { return nil }
        try RequestRuntime.wait(0.033)
        let pending = PendingResult<CGImage> { _ in }
        let task = Task {
            pending.complete(await Result {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == frame.windowID && $0.owningApplication?.processID == getpid() }) else {
                    throw ServiceError(.unknownError, "Capture overlay disappeared")
                }
                guard frame.bounds.width * frame.bounds.height * frame.scale * frame.scale <= 64_000_000 else {
                    throw ServiceError(.unknownError, "Overlay capture exceeds the image budget")
                }
                let config = SCStreamConfiguration()
                config.width = Int(round(frame.bounds.width * frame.scale)); config.height = Int(round(frame.bounds.height * frame.scale))
                config.showsCursor = false; config.shouldBeOpaque = false; config.ignoreShadowsSingleWindow = true
                config.captureResolution = .nominal
                return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            })
        }
        let image: CGImage?
        do {
            try RequestRuntime.wait(for: pending.signal, maximumSeconds: 5)
            let full = try pending.take(), sx = CGFloat(full.width) / frame.bounds.width, sy = CGFloat(full.height) / frame.bounds.height
            let crop = CGRect(x: frame.crop.minX * sx, y: (frame.bounds.height - frame.crop.maxY) * sy,
                width: frame.crop.width * sx, height: frame.crop.height * sy).integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            image = full.cropping(to: crop) ?? fallbackSnapshot()
        } catch {
            pending.abandon(); task.cancel(); try RequestRuntime.check(); image = fallbackSnapshot()
        }
        try RequestRuntime.check()
        guard let image else { return nil }
        let directory = Capture.temporaryDirectory.appendingPathComponent("transitions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("transition-\(UUID()).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ServiceError(.unknownError, "Could not encode transition snapshot") }
        let lease = CaptureFileLease(url: url, remove: { try? FileManager.default.removeItem(at: $0) })
        try data.write(to: url, options: .atomic)
        try RequestRuntime.check(); return lease
    }
    private func fallbackSnapshot() -> CGImage? {
        Self.main {
            guard lifecycle.phase == .arrived,
                  let overlay = overlays.first(where: { $0.frame.contains(CGPoint(x: destination.frame.midX, y: destination.frame.midY)) }) ?? overlays.first,
                  let layout = overlay.lastLayout else { return nil }
            let scale = overlay.display.scale, width = round(destination.frame.width * scale), height = round(metrics.snapshotHeight * scale)
            guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 64_000_000,
                  let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: scale, y: scale); context.setAllowsAntialiasing(true); context.interpolationQuality = .high
            context.translateBy(x: -layout.container.minX, y: metrics.snapshotHeight - layout.container.height - layout.container.minY)
            overlay.content.render(in: context); return context.makeImage()
        }
    }
}
