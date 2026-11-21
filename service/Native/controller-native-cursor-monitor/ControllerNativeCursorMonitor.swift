import AppKit
import ApplicationServices
import Foundation

/// The panel owns this handle and its monitor. The handle's native callbacks
/// hold the panel weakly, and the monitor holds the handle weakly.
@MainActor final class ControllerCursorMonitorWindow {
    let isVisible: () -> Bool
    let setApplicationReason: (Bool) -> Void
    let retarget: (UInt32) -> Void
    var appMonitor: ControllerNativeCursorAppMonitor?
    init(isVisible: @escaping () -> Bool, setApplicationReason: @escaping (Bool) -> Void, retarget: @escaping (UInt32) -> Void) {
        self.isVisible = isVisible; self.setApplicationReason = setApplicationReason; self.retarget = retarget
    }
}
typealias ControllerNativeCursorAppMonitor = ControllerCursorAppMonitor<ControllerAXEnablementApplication, ControllerNativeElementContext.Node, ControllerCursorMonitorWindow>

final class ControllerCursorNativeLease: ControllerCursorMonitorLease, @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func stop() { let previous = lock.withLock { let value = action; action = nil; return value }; previous?() }
    deinit { stop() }
}

extension ControllerCursorAppMonitor where Application == ControllerAXEnablementApplication, Node == ControllerNativeElementContext.Node, Window == ControllerCursorMonitorWindow {
    static func nativeEnvironment(resources: ControllerNativeResources) -> Environment {
        .init(runningApplication: { NSRunningApplication(processIdentifier: $0).map { .init(application: $0) } },
            isActive: { $0.application.isActive }, primaryWindow: { resources.context.context.primaryWindow($0) },
            windowID: { try resources.context.identity.windowID($0.element) }, isVisible: { $0.isVisible() },
            setApplicationOverlayReason: { $0.setApplicationReason($1) }, retargetVisibleWindow: { $0.retarget($1) },
            observeAX: { app, pid, names, callback in
                let observer = try ControllerAXNativeObserver(pid: pid) { _, name, _ in callback(name) }
                do {
                    for name in names {
                        let status = observer.add(app.element, name)
                        guard status == 0 || status == AXError.notificationAlreadyRegistered.rawValue else {
                            throw ControllerAXNativeObserver.Failure(status: status)
                        }
                    }
                    observer.start(.userInitiated)
                } catch { observer.stop(); throw error }
                return ControllerCursorNativeLease { observer.stop() }
            }, observeActive: { running, callback in
                let observation = running.application.observe(\.isActive, options: [.new]) { _, change in callback(change.newValue) }
                return ControllerCursorNativeLease { observation.invalidate() }
            }, enqueue: { work in Task { @MainActor in work() } })
    }
}

@MainActor struct ControllerNativeCursorCreationEnvironment {
    typealias Cursor = ControllerApprovedCursor
    typealias Node = ControllerNativeElementContext.Node
    let makeCursor: () -> Cursor
    let window: (Cursor) -> ControllerCursorMonitorWindow
    let application: (Int32) -> Node
    let monitor: (Node, Int32, ControllerCursorMonitorWindow) -> ControllerNativeCursorAppMonitor?
    static func native(resources: ControllerNativeResources) -> Self {
        .init(makeCursor: { let cursor = Cursor(); cursor.prepare(); return cursor },
            window: { $0.windowForMonitoring().monitorWindow }, application: { resources.context.application($0) },
            monitor: { .init(application: $0, pid: $1, window: $2, environment: ControllerNativeCursorAppMonitor.nativeEnvironment(resources: resources)) })
    }
}
@MainActor struct ControllerNativeCursorCreationBackend: ControllerCursorCreationBackend {
    typealias Cursor = ControllerApprovedCursor
    typealias Application = ControllerNativeElementContext.Node
    typealias Window = ControllerCursorMonitorWindow
    typealias Monitor = ControllerNativeCursorAppMonitor
    let controller: ControllerNativeAppController
    let environment: ControllerNativeCursorCreationEnvironment
    var current: Cursor? { get { controller.owner.virtualCursor } nonmutating set { controller.owner.virtualCursor = newValue } }
    var pid: Int32 { controller.owner.pid }
    func makeCursor() -> Cursor { environment.makeCursor() }
    func setCorrespondingApplicationPID(_ pid: Int32, cursor: Cursor) { cursor.correspondingApplicationPID = pid }
    func window(_ cursor: Cursor) -> Window { environment.window(cursor) }
    func application(_ pid: Int32) -> Application { environment.application(pid) }
    func makeMonitor(application: Application, pid: Int32, window: Window) -> Monitor? { environment.monitor(application, pid, window) }
    func installMonitor(_ monitor: Monitor?, window: Window) { window.appMonitor = monitor }
}
extension ControllerNativeAppController {
    func createVirtualCursorIfNeeded(environment: ControllerNativeCursorCreationEnvironment? = nil) -> ControllerApprovedCursor {
        ControllerCursorCreation(backend: ControllerNativeCursorCreationBackend(controller: self,
            environment: environment ?? .native(resources: resources))).ensure()
    }
}
