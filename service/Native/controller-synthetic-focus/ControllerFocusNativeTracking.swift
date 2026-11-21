import AppKit
import Foundation

/// The focus owner always constructs excludeCurrentApp:false.
/// Keep a per-owner tracker and its ordered strong observer array. Workspace
/// notifications are synchronous on the posting thread, with no actor hop.
final class ControllerFocusNativeTracking: ControllerFocusTracking, @unchecked Sendable {
    private final class Observation: ControllerFocusObservation, @unchecked Sendable {
        let handler: @Sendable (Int32) -> Void
        weak var owner: ControllerFocusNativeTracking?
        init(_ owner: ControllerFocusNativeTracking, _ handler: @escaping @Sendable (Int32) -> Void) {
            self.owner = owner; self.handler = handler
        }
        func remove() { owner?.remove(self) }
    }
    private let center: NotificationCenter
    private let stateLock = NSLock()
    private var saved: NSRunningApplication?
    private let observersLock = NSLock()
    private var observers: [Observation] = []
    private var workspaceObserver: NSObjectProtocol?
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         initial: NSRunningApplication? = NSWorkspace.shared.menuBarOwningApplication) {
        self.center = center; saved = initial
        workspaceObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil) { [weak self] notification in
                guard let self, let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.receive(application)
            }
    }
    private func receive(_ application: NSRunningApplication) {
        let changed = stateLock.withLock {
            if let saved, saved.isEqual(application) { return false }
            saved = application; return true
        }
        guard changed else { return }
        let snapshot = observersLock.withLock { observers }
        for observer in snapshot { observer.handler(application.processIdentifier) }
    }
    func observe(_ handler: @escaping @Sendable (Int32) -> Void) -> any ControllerFocusObservation {
        let observation = Observation(self, handler)
        observersLock.withLock { observers.append(observation) }
        return observation
    }
    private func remove(_ observation: Observation) {
        observersLock.withLock { observers.removeAll { $0 === observation } }
    }
    deinit { if let workspaceObserver { center.removeObserver(workspaceObserver) } }
}
