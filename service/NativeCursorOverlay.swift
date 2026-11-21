import AppKit
import QuartzCore

/// Agent cursor overlay: cursor window, cursor shape and motion path.
///
/// Uses the rounded AgentCursor silhouette with equally sized rear wings, a
/// pearl finish and a soft motion glow. The shape keeps its proportions in transit;
/// the arrow tip stays at the action coordinate during click compression.
/// All AppKit work is marshalled onto the main thread.
final class CursorOverlay {
    static let shared = CursorOverlay()

    // Room for the outline, shadow and motion outside the path's bounding box.
    // A 16.5 pt path renders at the native arrow's 17.5 pt solid height with the rim.
    static let onScreenHeight = CursorArtwork.onScreenHeight
    static let drawingInset = CursorArtwork.drawingInset
    private static let motionGlowName = CursorArtwork.motionGlowName
    private static let agentLabelName = CursorArtwork.agentLabelName
    private lazy var layout = Self.cursorLayout()

    private typealias CursorLayout = CursorArtwork.CursorLayout
    private static func cursorLayout(scale: CGFloat = 1) -> CursorLayout {
        CursorArtwork.cursorLayout(scale: scale)
    }

    // --- tuned motion configuration ---
    private let startHandle: CGFloat = 0.35
    private let endpointHandle: CGFloat = 0.35
    private let arcSize: CGFloat = 0.06
    private let straightPathDistanceThreshold: CGFloat = 40
    private let springResponse: Double = 0.28
    private let springDamping: Double = 1.0

    // --- state ---
    private let windowFactory: @MainActor (NSRect) -> NSPanel
    private let nativeAppearance: ControllerNativeCursorAppearance.Environment?
    private let nativeMotionConfiguration: ControllerCursorMotionEngine.Configuration
    private var nativeMoveSetupInProgress = false
    private var nativeMotionActive = false
    private var nativeTrackedWindowID: UInt32?
    private var nativeInterpolatedOrigin = CGPoint.zero
    private var nativeMotionEvents: ControllerCursorAnimationEvents?
    private var nativeDisplayDriver: SystemSettingsDisplayLinkDriver?
    @MainActor private final class NativeFrameDelivery {
        let receive: @MainActor (SystemSettingsAnimationFrame) -> Void
        init(_ receive: @escaping @MainActor (SystemSettingsAnimationFrame) -> Void) { self.receive = receive }
    }
    init(windowFactory: @escaping @MainActor (NSRect) -> NSPanel = { NSPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false) },
         nativeAppearance: ControllerNativeCursorAppearance.Environment? = nil,
         nativeMotionConfiguration: ControllerCursorMotionEngine.Configuration = .init()) {
        self.windowFactory = windowFactory; self.nativeAppearance = nativeAppearance
        self.nativeMotionConfiguration = nativeMotionConfiguration
        onMain { MainActor.assumeIsolated { PIPCursorRegistry.shared.add(self) } }
    }
    func nativeMovementIsActive() -> Bool { var result = false; onMain { result = self.nativeMotionActive }; return result }
    func nativePressedState() -> Bool { var result = false; onMain { result = self.pressScale == 0.94 }; return result }
    func windowForMonitoring() -> NSPanel { var panel: NSPanel?; onMain { panel = self.ensureWindow() as? NSPanel }; return panel! }
    private var window: NSWindow?
    private var motionLayer: CALayer?
    private var pressLayer: CALayer?
    private var glowLayer: CALayer?
    private var labelLayer: CALayer?
    private var glowIsMoving = false
    private var timer: Timer?
    private let motionCompletion = CursorMotionCompletion()
    private var idleTimer: Timer?
    private var arcFlow: CGFloat = 1
    private var visible = false
    private var pressScale = 1.0
    private var targetWindowID: CGWindowID?
    private var lastReportedPosition: CGPoint?
    private var locationObserver: ((CGPoint?, CGWindowID?, CGWindowID?) -> Void)?

    // spring/anim state
    private var progress: Double = 1
    private var velocity: Double = 0
    private var pathStart: CGPoint = .zero
    private var pathControl1: CGPoint = .zero
    private var pathControl2: CGPoint = .zero
    private var pathEnd: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var prevPosition: CGPoint = .zero

    // MARK: - public API (thread-safe)

    func prepare() { onMain { self.prepareMain() } }
    func prepareInteraction() -> Bool {
        var shown = false
        onMain { shown = self.ensureWindow()?.isVisible ?? false }
        return shown
    }
    func observeLocation(_ observer: @escaping (CGPoint?, CGWindowID?, CGWindowID?) -> Void) {
        onMain { self.locationObserver = observer }
    }
    func place(at cgPoint: CGPoint, active: Bool = true, animated: Bool = true, targetWindowID: CGWindowID? = nil,
               relativeToWindow: Bool = true,
               nextInteractionTiming: CursorInteractionTiming = .finished,
               completion: ((Bool) -> Void)? = nil) {
        onMain {
            if let appearance = self.nativeAppearance {
                self.updateTargetWindow(relativeToWindow ? targetWindowID : nil)
                MainActor.assumeIsolated {
                    self.placeNativeMain(cgPoint, aboveWindowID:targetWindowID, relativeToWindow:relativeToWindow,
                        animated:animated, timing:nextInteractionTiming, completion:completion, appearance:appearance)
                }
                return
            }
            let token = self.motionCompletion.begin(completion, timing: nextInteractionTiming)
            guard self.motionCompletion.isCurrent(token) else { return }
            self.updateTargetWindow(targetWindowID)
            self.placeMain(cgPoint, active: active, animated: animated, token: token)
        }
    }
    @discardableResult
    func press(animationDuration: TimeInterval = 0.12) -> Bool {
        var shown = false
        onMain {
            guard let window = self.ensureWindow() else { return }
            shown = window.isVisible
            self.pressMain(duration: animationDuration)
        }
        return shown
    }
    func setPressed(_ pressed: Bool) {
        onMain {
            guard self.ensureWindow() != nil else { return }
            self.setPressedMain(pressed)
        }
    }
    func drag(from: CGPoint, to: CGPoint, duration: TimeInterval = 0.4, targetWindowID: CGWindowID? = nil) {
        onMain {
            let token = self.motionCompletion.begin(nil)
            guard self.motionCompletion.isCurrent(token) else { return }
            self.updateTargetWindow(targetWindowID)
            self.dragMain(from: from, to: to, duration: duration, token: token)
        }
    }
    func hide() { onMain { self.hideMain() } }
    /// Per-owner capture sampling; this accessor never creates a window.
    func currentVisibleWindowID() -> UInt32? {
        var result: UInt32?
        onMain {
            if let window = self.window, window.isVisible, window.windowNumber > 0 {
                result = UInt32(window.windowNumber)
            }
        }
        return result
    }


    private func updateTargetWindow(_ id: CGWindowID?) {
        if targetWindowID != id { lastReportedPosition = nil }
        targetWindowID = id
    }

    private func finishMotion(_ token: UUID, completed: Bool) {
        guard motionCompletion.isCurrent(token) else { return }
        motionCompletion.finish(token,completed:completed)
        MainActor.assumeIsolated {
            NotificationCenter.default.post(name:PIPCursorRegistry.didFinishMove,object:self)
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
    }

    // MARK: - shape

    static let baseOrientationDegrees = CursorArtwork.baseOrientationDegrees
    static func cursorGeometry() -> (path: CGPath, boxSize: CGSize, tipFraction: CGPoint) {
        CursorArtwork.cursorGeometry()
    }
    static func agentCursorPath(in rect: CGRect) -> CGPath { CursorArtwork.agentCursorPath(in: rect) }
    static func makeCursorArtwork(scale: CGFloat = 1, glowIntensity: Float = 0) -> CALayer {
        CursorArtwork.makeCursorArtwork(scale: scale, glowIntensity: glowIntensity)
    }

    /// Same cubic as `buildMotionPath`, exposed for tracing/tests.
    static func sampledMotionPath(from a: CGPoint, to b: CGPoint, steps: Int = 12,
                                  startHandle: CGFloat = 0.35, endpointHandle: CGFloat = 0.35,
                                  arcSize: CGFloat = 0.06, straightThreshold: CGFloat = 40,
                                  arcFlow: CGFloat = 1) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = (dx * dx + dy * dy).squareRoot()
        var c1 = CGPoint.zero, c2 = CGPoint.zero
        if distance < straightThreshold {
            c1 = CGPoint(x: a.x + dx / 3, y: a.y + dy / 3)
            c2 = CGPoint(x: a.x + 2 * dx / 3, y: a.y + 2 * dy / 3)
        } else {
            let nx = -dy / distance, ny = dx / distance
            let bow = min(arcSize * distance, 24) * arcFlow
            c1 = CGPoint(x: a.x + dx * startHandle + nx * bow, y: a.y + dy * startHandle + ny * bow)
            c2 = CGPoint(x: b.x - dx * endpointHandle + nx * bow, y: b.y - dy * endpointHandle + ny * bow)
        }
        return (0...steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps), mt = 1 - t
            let w0 = mt*mt*mt, w1 = 3*mt*mt*t, w2 = 3*mt*t*t, w3 = t*t*t
            return CGPoint(x: w0*a.x + w1*c1.x + w2*c2.x + w3*b.x, y: w0*a.y + w1*c1.y + w2*c2.y + w3*b.y)
        }
    }

    // MARK: - window

    private func prepareMain() {
        guard let window = ensureWindow() else { return }
        window.alphaValue = 0
        window.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow? {
        if let window { return window }
        let frame = NSRect(origin: .zero, size: layout.canvasSize)
        // These private paths run inside onMain or a main-run-loop timer.
        let window = MainActor.assumeIsolated { windowFactory(frame) }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = window is ControllerNativeCursorWindow ? .normal : .screenSaver
        window.ignoresMouseEvents = true
        if let native = window as? ControllerNativeCursorWindow {
            MainActor.assumeIsolated {
                native.tipOffset = layout.hotspot
                native.stopCursorMotion = { [weak self] in self?.stopForWindowOrdering() }
                native.cursorStyleUpdated = { [weak self] in self?.motionLayer?.setNeedsDisplay() }
            }
        }
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        let artwork = Self.makeCursorArtwork()
        let motion = CALayer()
        motion.bounds = artwork.bounds
        motion.anchorPoint = artwork.anchorPoint
        let pivot = layout.hotspot
        motion.position = pivot
        artwork.position = pivot
        motion.addSublayer(artwork)
        view.layer?.addSublayer(motion)
        // Keep the label upright and steady while the arrow tilts or presses.
        let label = artwork.sublayers?.first { $0.name == Self.agentLabelName }
        label?.removeFromSuperlayer()
        if let label { view.layer?.addSublayer(label) }

        window.contentView = view
        self.window = window
        self.motionLayer = motion
        self.pressLayer = artwork
        self.glowLayer = artwork.sublayers?.first { $0.name == Self.motionGlowName }
        self.labelLayer = label
        return window
    }

    private func frame(forCGPoint cgPoint: CGPoint) -> NSRect {
        Self.windowFrame(at: cgPoint, primaryHeight: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    static func windowFrame(at cgPoint: CGPoint, primaryHeight: CGFloat) -> NSRect {
        let layout = cursorLayout()
        return NSRect(
            x: cgPoint.x - layout.hotspot.x,
            y: primaryHeight - cgPoint.y - layout.hotspot.y,
            width: layout.canvasSize.width,
            height: layout.canvasSize.height)
    }

    // MARK: - bezier motion

    private func buildMotionPath(from a: CGPoint, to b: CGPoint) {
        pathStart = a
        pathEnd = b
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < straightPathDistanceThreshold {
            pathControl1 = CGPoint(x: a.x + dx / 3, y: a.y + dy / 3)
            pathControl2 = CGPoint(x: a.x + 2 * dx / 3, y: a.y + 2 * dy / 3)
            return
        }
        // Perpendicular offset gives the gentle arc; alternate the side so
        // successive moves do not all bow the same way.
        let nx = -dy / distance, ny = dx / distance
        let bow = min(arcSize * distance, 24) * arcFlow
        pathControl1 = CGPoint(x: a.x + dx * startHandle + nx * bow, y: a.y + dy * startHandle + ny * bow)
        pathControl2 = CGPoint(x: b.x - dx * endpointHandle + nx * bow, y: b.y - dy * endpointHandle + ny * bow)
        arcFlow *= -1
    }

    private func bezier(_ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(
            x: a * pathStart.x + b * pathControl1.x + c * pathControl2.x + d * pathEnd.x,
            y: a * pathStart.y + b * pathControl1.y + c * pathControl2.y + d * pathEnd.y)
    }

    private func startSpring(token: UUID) {
        timer?.invalidate()
        if nativeMotionActive, let window {
            timer = nil
            MainActor.assumeIsolated {
                stopNativeDriver()
                let driver = SystemSettingsDisplayLinkDriver(window:window)
                let delivery = NativeFrameDelivery { [weak self] frame in
                    self?.stepNative(frame:frame,token:token)
                }
                driver.frameCallback = { [delivery] frame in delivery.receive(frame) }
                nativeDisplayDriver = driver
                driver.start()
            }
            return
        }
        progress = 0
        velocity = 0
        let interval = 1.0 / 120.0
        var last = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self, self.motionCompletion.isCurrent(token) else { t.invalidate(); return }
            let now = CACurrentMediaTime()
            let dt = min(now - last, 0.05)
            last = now
            self.step(dt: dt, token: token)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func step(dt: Double, token: UUID) {
        guard motionCompletion.isCurrent(token) else { return }
        let omega = 2 * Double.pi / springResponse
        let zeta = springDamping
        let x = progress - 1
        let accel = -omega * omega * x - 2 * zeta * omega * velocity
        velocity += accel * dt
        progress += velocity * dt
        if abs(progress - 1) < 0.002 && abs(velocity) < 0.02 {
            progress = 1
            apply(position: bezier(1), velocity: 0)
            guard motionCompletion.isCurrent(token) else { return }
            timer?.invalidate(); timer = nil
            if nativeAppearance != nil { finishNativeMovement(token) }
            else { finishMotion(token, completed: true) }
            return
        }
        let t = CGFloat(min(max(progress, 0), 1.15))
        let point = bezier(min(t, 1))
        apply(position: point, velocity: CGFloat(velocity), moving: true)
        guard motionCompletion.isCurrent(token) else { return }
        motionCompletion.advance(token, progress: progress,
            distance: Double(hypot(point.x - pathEnd.x, point.y - pathEnd.y)))
    }

    private func stepNative(frame tick: SystemSettingsAnimationFrame, token: UUID) {
        guard motionCompletion.isCurrent(token), var animation = nativeMotionEvents else { return }
        let events = animation.advance(timestamp:tick.timestamp,targetTimestamp:tick.targetTimestamp)
        nativeMotionEvents = animation
        for event in events {
            guard motionCompletion.isCurrent(token), nativeMotionActive else { return }
            switch event {
            case .valueChanged(let frame):
                apply(position:frame.point,velocity:hypot(frame.velocity.x,frame.velocity.y),moving:true)
                guard motionCompletion.isCurrent(token) else { return }
                motionCompletion.advance(token,progress:frame.progress,distance:frame.distance)
            case .finished(let frame):
                apply(position:frame.point,velocity:0)
                guard motionCompletion.isCurrent(token) else { return }
                // A stationary run has no valueChanged event. Its finished
                // handler still releases readiness before visual cleanup.
                motionCompletion.advance(token,progress:1,distance:0)
                guard motionCompletion.isCurrent(token), nativeMotionActive else { return }
                stopNativeDriver()
                finishNativeMovement(token)
            }
        }
    }

    private func stopNativeDriver() {
        MainActor.assumeIsolated {
            nativeDisplayDriver?.frameCallback = nil
            nativeDisplayDriver?.stop()
            nativeDisplayDriver = nil
        }
    }

    private func apply(position: CGPoint, velocity v: CGFloat, moving: Bool = false) {
        guard let window else { return }
        let displayedPoint: CGPoint
        if nativeMotionActive, let appearance = nativeAppearance {
            nativeInterpolatedOrigin = position
            let height = NSScreen.screens.first?.frame.maxY ?? 0
            let origin = MainActor.assumeIsolated {
                nativeTrackedWindowID.flatMap { appearance.targetFrame($0,height)?.origin }
            }
            let global = ControllerCursorMovePlan.globalOrigin(local:position,currentTargetOrigin:origin)
            window.setFrameOrigin(.init(x:global.x.rounded(),y:global.y.rounded()))
            displayedPoint = .init(x:window.frame.minX+layout.hotspot.x,y:height-window.frame.minY-layout.hotspot.y)
        } else {
            window.setFrame(frame(forCGPoint: position), display: true)
            displayedPoint = position
        }
        MainActor.assumeIsolated { (window as? ControllerNativeCursorWindow)?.cursorMoved() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        motionLayer?.transform = CATransform3DIdentity
        CATransaction.commit()
        let distance = hypot(displayedPoint.x - prevPosition.x, displayedPoint.y - prevPosition.y)
        updateMotionGlow(moving: moving && distance > 0.02)
        if ProcessInfo.processInfo.environment["ACUA_CURSOR_TRACE"] == "1" {
            print(String(format: "[cursor-move] (%.1f, %.1f) v=%.3f", position.x, position.y, Double(v)))
        }
        prevPosition = displayedPoint
        lastPoint = displayedPoint
        if displayedPoint != lastReportedPosition, let id = CGWindowID(exactly: window.windowNumber), id != 0 {
            lastReportedPosition = displayedPoint
            locationObserver?(displayedPoint, id, targetWindowID)
        }
    }

    private func updateMotionGlow(moving: Bool, immediately: Bool = false) {
        let enabled = moving && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let layer = glowLayer, enabled != glowIsMoving || immediately else { return }
        glowIsMoving = enabled
        let target: Float = enabled ? 0.55 : 0
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "glowFade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        if !immediately {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = current
            fade.toValue = target
            fade.duration = enabled ? 0.12 : 0.24
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "glowFade")
        }
    }

    // MARK: - placement

    @MainActor private func placeNativeMain(_ point: CGPoint, aboveWindowID: UInt32?, relativeToWindow: Bool,
        animated: Bool, timing: CursorInteractionTiming,
        completion: ((Bool) -> Void)?, appearance: ControllerNativeCursorAppearance.Environment) {
        guard let window = ensureWindow() as? ControllerNativeCursorWindow else { completion?(false); return }
        let reply = ControllerCursorMoveReply(completion)
        let token = motionCompletion.begin({ value in MainActor.assumeIsolated { reply.moveFinished(value) } },timing:timing)
        guard motionCompletion.isCurrent(token) else { return }
        window.updateConstraintsIfNeeded(); window.displayIfNeeded()
        let wasVisible = window.isVisible, originalFrame = window.frame
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        let goalFrame = frame(forCGPoint:point)
        let capturedFrame = relativeToWindow ? aboveWindowID.flatMap { appearance.targetFrame($0,height) } : nil
        let pet = appearance.petLocation()
        let interpolated = nativeMotionActive && (timer != nil || nativeDisplayDriver != nil) ? nativeInterpolatedOrigin : nil
        let plan = ControllerCursorMovePlan(frame:originalFrame,destinationOrigin:goalFrame.origin,hotspot:layout.hotspot,
            petLocation:pet,wasVisible:wasVisible,animated:animated,targetFrame:capturedFrame,interpolatedOrigin:interpolated)
        nativeMoveSetupInProgress = true
        defer { nativeMoveSetupInProgress = false }
        window.stopMotionBeforeNextMove()
        nativeInterpolatedOrigin = plan.localStart
        if !wasVisible { window.setFrameOrigin(plan.initialWindowOrigin) }
        if !wasVisible && animated { ControllerNativeCursorAppearance.prepareHidden(window:window,layer:window.contentView?.layer) }
        window.showForCursor(relativeTo:aboveWindowID,temporaryOverlay:plan.temporaryOverlay)
        let animate = plan.shouldAnimate(windowIsVisible:{ window.isVisible },hasScreen:{ window.screen != nil },
            aboveWindowID:aboveWindowID,hotspot:layout.hotspot,hitWindow:{ appearance.hitWindow($0) })
        if !animate {
            window.clearMovementReason()
            nativeMotionActive = false; nativeTrackedWindowID = nil
            apply(position:point,velocity:0)
            guard motionCompletion.isCurrent(token) else { return }
            visible = window.isVisible
            if ControllerCursorMovePlan.needsFade(wasVisible:wasVisible,animated:animated,fadeIn:false,didAnimate:false) {
                reply.deferToFade()
                finishMotion(token,completed:true)
                appearance.fade(window,window.contentView?.layer) { reply.fadeFinished() }
            } else {
                if !wasVisible { window.alphaValue = 1 }
                finishMotion(token,completed:true)
            }
            return
        }
        nativeMotionActive = true
        nativeTrackedWindowID = capturedFrame == nil ? nil : aboveWindowID
        ControllerNativeCursorAppearance.beginMotion(window:window,layer:window.contentView?.layer)
        let bounds = ControllerCursorMotionPath.bounds(start:plan.localStart,end:plan.localEnd,
            targetFrame:capturedFrame,screens:NSScreen.screens.map(\.frame))
        nativeMotionEvents = .init(start:plan.localStart,end:plan.localEnd,bounds:bounds,configuration:nativeMotionConfiguration)
        apply(position:plan.localStart,velocity:0)
        guard motionCompletion.isCurrent(token) else { return }
        visible = window.isVisible
        nativeMoveSetupInProgress = false
        startSpring(token:token)
    }

    private func finishNativeMovement(_ token: UUID) {
        guard motionCompletion.isCurrent(token) else { return }
        nativeMotionActive = false; nativeTrackedWindowID = nil
        nativeMotionEvents = nil
        stopNativeDriver()
        nativeMoveSetupInProgress = true
        MainActor.assumeIsolated { (window as? ControllerNativeCursorWindow)?.clearMovementReason() }
        nativeMoveSetupInProgress = false
        finishMotion(token,completed:true)
    }

    private func placeMain(_ cgPoint: CGPoint, active: Bool, animated: Bool, token: UUID) {
        guard let window = ensureWindow() else { finishMotion(token, completed: false); return }
        guard motionCompletion.isCurrent(token) else { return }
        window.alphaValue = 1
        if let native = window as? ControllerNativeCursorWindow {
            MainActor.assumeIsolated { native.showForCursor(relativeTo: targetWindowID, temporaryOverlay: false) }
        } else { window.orderFrontRegardless() }
        motionLayer?.opacity = active ? 1.0 : 0.65
        labelLayer?.opacity = active ? 1.0 : 0.65

        let animating = animated && visible && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animating {
            buildMotionPath(from: lastPoint, to: cgPoint)
            prevPosition = lastPoint
            startSpring(token: token)
        } else {
            timer?.invalidate(); timer = nil
            apply(position: cgPoint, velocity: 0)
            guard motionCompletion.isCurrent(token) else { return }
            prevPosition = cgPoint
        }
        visible = true
        scheduleIdleHide()
        if !animating { finishMotion(token, completed: true) }
    }

    private func setPressedMain(_ pressed: Bool) {
        let next = pressed ? 0.94 : 1.0
        let previous = pressScale
        pressScale = next
        guard let layer = pressLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(next, forKeyPath: "transform.scale")
        CATransaction.commit()
        guard visible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let anim = CASpringAnimation(keyPath: "transform.scale")
        anim.fromValue = previous
        anim.toValue = next
        anim.duration = NativeMouseClick.seconds(NativeMouseClick.pressAnimation)
        anim.damping = 18
        anim.initialVelocity = 0
        layer.add(anim, forKey: "press")
    }

    private func pressMain(duration: TimeInterval = 0.12) {
        guard let layer = pressLayer, visible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let anim = CASpringAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 0.94
        anim.duration = duration
        anim.autoreverses = true
        anim.damping = 18
        anim.initialVelocity = 0
        layer.add(anim, forKey: "press")
    }

    private func dragMain(from: CGPoint, to: CGPoint, duration: TimeInterval, token: UUID) {
        guard let window = ensureWindow() else { finishMotion(token, completed: false); return }
        guard motionCompletion.isCurrent(token) else { return }
        timer?.invalidate(); timer = nil
        window.alphaValue = 1
        if let native = window as? ControllerNativeCursorWindow {
            MainActor.assumeIsolated { native.showForCursor(relativeTo: targetWindowID, temporaryOverlay: false) }
        } else { window.orderFrontRegardless() }
        motionLayer?.opacity = 1
        labelLayer?.opacity = 1
        prevPosition = from
        apply(position: from, velocity: 0)
        guard motionCompletion.isCurrent(token) else { return }
        // A drag must track the actual event's straight path and duration.
        // Decorative arcs and spring settling would detach it from the object.
        let animating = duration.isFinite && duration > 0
        if animating {
            let start = CACurrentMediaTime()
            timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
                guard let self, self.motionCompletion.isCurrent(token) else { timer.invalidate(); return }
                let t = CGFloat(min((CACurrentMediaTime() - start) / duration, 1))
                self.apply(position: CGPoint(x: from.x + (to.x - from.x) * t,
                                             y: from.y + (to.y - from.y) * t), velocity: 0, moving: t < 1)
                guard self.motionCompletion.isCurrent(token) else { timer.invalidate(); return }
                if t >= 1 {
                    timer.invalidate(); self.timer = nil
                    self.finishMotion(token, completed: true)
                }
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else {
            apply(position: to, velocity: 0)
            guard motionCompletion.isCurrent(token) else { return }
        }
        visible = true
        scheduleIdleHide()
        if !animating { finishMotion(token, completed: true) }
    }

    private func scheduleIdleHide() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.hideMain() }
    }

    private func stopForWindowOrdering() {
        timer?.invalidate(); timer = nil
        nativeMotionActive = false; nativeTrackedWindowID = nil
        nativeMotionEvents = nil
        stopNativeDriver()
        pressLayer?.removeAnimation(forKey: "press")
        updateMotionGlow(moving: false, immediately: true)
        if nativeAppearance == nil { setPressedMain(false) }
        if !nativeMoveSetupInProgress, let token = motionCompletion.currentToken { finishMotion(token, completed: false) }
    }

    private func hideMain() {
        let token = motionCompletion.currentToken
        idleTimer?.invalidate(); idleTimer = nil
        timer?.invalidate(); timer = nil
        pressLayer?.removeAnimation(forKey: "press")
        updateMotionGlow(moving: false, immediately: true)
        window?.orderOut(nil)
        let wasVisible = visible
        visible = false
        if nativeAppearance == nil { setPressedMain(false) }
        lastReportedPosition = nil
        targetWindowID = nil
        lastPoint = .zero
        if wasVisible { locationObserver?(nil, nil, nil) }
        if let token { finishMotion(token, completed: false) }
    }

    // MARK: - diagnostics
    func debugState(label: String) {
        onMain {
            let w = self.window
            let pid = ProcessInfo.processInfo.processIdentifier
            let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
            let mine = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            let server = mine.map { "onscreen=\($0[kCGWindowIsOnscreen as String] ?? "?") bounds=\($0[kCGWindowBounds as String] ?? "?")" }.joined(separator: " | ")
            print("[cursor] \(label): appkit=\(w.map { NSStringFromRect($0.frame) } ?? "nil") server=[\(server)]")
        }
    }
}

extension CursorOverlay: PIPCaptureCursor {
    @MainActor var pipTargetWindowID: UInt32? { targetWindowID }
    @MainActor var pipIsVisible: Bool { window?.isVisible ?? false }
    @MainActor var pipWindowNumber: Int { window?.windowNumber ?? 0 }
}
