import Foundation

protocol ControllerCursorMonitorLease: AnyObject, Sendable { func stop() }

/// Watches the cursor's app. The window is weak, observations retain neither the
/// monitor nor window, and an already-promoted queued callback retains self.
@MainActor final class ControllerCursorAppMonitor<Application: Sendable, Node: Sendable, Window: AnyObject> {
    @MainActor struct Environment {
        let runningApplication: (Int32) -> Application?
        let isActive: (Application) -> Bool
        let primaryWindow: (Node) -> Node?
        let windowID: (Node) throws -> UInt32
        let isVisible: (Window) -> Bool
        let setApplicationOverlayReason: (Window, Bool) -> Void
        let retargetVisibleWindow: (Window, UInt32) -> Void
        let observeAX: (Node, Int32, [String], @escaping @Sendable (String) -> Void) throws -> any ControllerCursorMonitorLease
        let observeActive: (Application, @escaping @Sendable (Bool?) -> Void) -> any ControllerCursorMonitorLease
        let enqueue: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    }
    static var notifications: [String] { ["AXFocusedWindowChanged", "AXMenuOpened", "AXMenuClosed"] }
    let runningApplication: Application
    let application: Node
    private let environment: Environment
    private weak var window: Window?
    private var axObservation: (any ControllerCursorMonitorLease)?
    private var activeObservation: (any ControllerCursorMonitorLease)?
    private(set) var isActive = false
    private(set) var openMenus = 0

    init?(application: Node, pid: Int32, window: Window, environment: Environment) {
        guard let running = environment.runningApplication(pid) else { return nil }
        self.runningApplication = running; self.application = application
        self.window = window; self.environment = environment
        let enqueue = environment.enqueue
        // AX constructor/registration errors are swallowed; the monitor still
        // installs active-state observation and samples the running app.
        axObservation = try? environment.observeAX(application, pid, Self.notifications) { [weak self] name in
            guard let self else { return }
            enqueue { self.receive(name) }
        }
        activeObservation = environment.observeActive(running) { [weak self] value in
            guard let self else { return }
            enqueue { self.activeChanged(value) }
        }
        isActive = environment.isActive(running)
        updateOverlayReason()
    }
    func activeChanged(_ value: Bool?) {
        isActive = value ?? false
        updateOverlayReason()
    }
    func receive(_ notification: String) {
        switch notification {
        case "AXFocusedWindowChanged":
            // Resolve/read before checking the weak window.
            guard let primary = environment.primaryWindow(application),
                  let id = try? environment.windowID(primary) else { return }
            if let window, environment.isVisible(window) { environment.retargetVisibleWindow(window, id) }
        case "AXMenuOpened":
            openMenus += 1; updateOverlayReason()
        case "AXMenuClosed":
            // Checked signed arithmetic, with no clamp.
            openMenus -= 1; updateOverlayReason()
        default: break
        }
    }
    private func updateOverlayReason() {
        if let window { environment.setApplicationOverlayReason(window, isActive || openMenus > 0) }
    }
    deinit { axObservation?.stop(); activeObservation?.stop() }
}
