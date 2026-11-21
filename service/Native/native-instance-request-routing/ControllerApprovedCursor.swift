import AppKit

/// Retains the approved cursor artwork and motion implementation. Access is on
/// MainActor; each native controller can own its own existing CursorOverlay.
@MainActor final class ControllerApprovedCursor {
    private let overlay: CursorOverlay
    // The software style stores activity without replacing its artwork.
    // 0=acting, 1=finished, 2=user interruption. The approved glow still follows
    //movement; the Fog style and its visibility transform are a separate gate.
    var activityState: UInt8 = 0
    let motionConfiguration: ControllerCursorMotionEngine.Configuration
    var correspondingApplicationPID: Int32?
    init(appearance: ControllerNativeCursorAppearance.Environment? = nil,
         motionConfiguration: ControllerCursorMotionEngine.Configuration = .init()) {
        self.motionConfiguration = motionConfiguration
        overlay = CursorOverlay(windowFactory: { ControllerNativeCursorWindow(frame: $0) }, nativeAppearance: appearance ?? .native,
            nativeMotionConfiguration: motionConfiguration)
    }
    var isMoving: Bool { overlay.nativeMovementIsActive() }
    var isPressed: Bool { overlay.nativePressedState() }
    func press(count: Int = 1) async throws {
        try await ControllerClickCursorPress(visible: { self.visibleWindowID != nil }, pressed: setPressed,
            wait: { try await Task.sleep(for: $0) }).press(count: count)
    }
    func windowForMonitoring() -> ControllerNativeCursorWindow { overlay.windowForMonitoring() as! ControllerNativeCursorWindow }
    func prepare() { overlay.prepare() }
    func hide() { overlay.hide() }
    var visibleWindowID: UInt32? { overlay.currentVisibleWindowID() }
    func setPressed(_ value: Bool) { overlay.setPressed(value) }
    func place(at point: CGPoint, active: Bool, animated: Bool, targetWindowID: UInt32?,
               relativeToWindow: Bool = true,
               timing: CursorInteractionTiming, completion: ((Bool) -> Void)? = nil) {
        overlay.place(at: point, active: active, animated: animated, targetWindowID: targetWindowID,
            relativeToWindow: relativeToWindow, nextInteractionTiming: timing, completion: completion)
    }
    func move(to point: CGPoint, aboveWindowID: UInt32?, relativeToWindow: Bool,
              timing: CursorInteractionTiming, animated: Bool, notificationCenter: NotificationCenter = .default) async {
        await withCheckedContinuation { continuation in
            place(at: point, active: true, animated: animated, targetWindowID: aboveWindowID,
                relativeToWindow: relativeToWindow, timing: timing) { _ in continuation.resume() }
        }
        notificationCenter.post(name: .init("computerUseCursorDidFinishMove"), object: self)
    }
    /// This is also called for a supplied installer cursor, independently of
    /// the lazy controller factory. Replace the old monitor after creating new.
    func setCorrespondingApplication(pid: Int32, environment: ControllerNativeCursorCreationEnvironment) {
        correspondingApplicationPID = pid
        let window = environment.window(self)
        let application = environment.application(pid)
        window.appMonitor = environment.monitor(application, pid, window)
    }
}

extension ControllerNativeOwnerAssembly where Cursor == ControllerApprovedCursor {
    static func approvedCursorNative(analytics: @escaping @Sendable (Owner.Analytics) -> Void,
                                     orderingLog: @escaping @Sendable (Ordering.Log) -> Void,
                                     log: @escaping @Sendable (String, any Error) -> Void) throws -> Self {
        try native(analytics: analytics, orderingLog: orderingLog, hideCursor: { $0.hide() }, log: log)
    }
}
