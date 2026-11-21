import Foundation

@MainActor protocol ControllerCursorCreationBackend {
    associatedtype Cursor
    associatedtype Application
    associatedtype Window
    associatedtype Monitor
    var current: Cursor? { get nonmutating set }
    var pid: Int32 { get }
    func makeCursor() -> Cursor
    func setCorrespondingApplicationPID(_ pid: Int32, cursor: Cursor)
    func window(_ cursor: Cursor) -> Window
    func application(_ pid: Int32) -> Application
    func makeMonitor(application: Application, pid: Int32, window: Window) -> Monitor?
    func installMonitor(_ monitor: Monitor?, window: Window)
}
@MainActor struct ControllerCursorCreation<Backend: ControllerCursorCreationBackend> {
    let backend: Backend
    /// Publish the new cursor before assigning PID and making its
    /// window monitor. An existing cursor bypasses every construction effect.
    func ensure() -> Backend.Cursor {
        if let existing = backend.current { return existing }
        let cursor = backend.makeCursor()
        backend.current = cursor
        let pid = backend.pid
        backend.setCorrespondingApplicationPID(pid, cursor: cursor)
        let window = backend.window(cursor)
        let application = backend.application(pid)
        let monitor = backend.makeMonitor(application: application, pid: pid, window: window)
        backend.installMonitor(monitor, window: window)
        return cursor
    }
}
