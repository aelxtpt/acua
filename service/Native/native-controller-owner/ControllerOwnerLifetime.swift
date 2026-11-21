import AppKit
import Foundation

protocol ControllerOwnerLifetime: AnyObject, Sendable { func cancel() }

/// The controller owns one main-queue Workspace termination token.
final class ControllerWorkspaceTermination: ControllerOwnerLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    init(center: NotificationCenter, name: Notification.Name,
         handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
    }
    static func workspace(_ handler: @escaping @Sendable (Notification) -> Void) -> ControllerWorkspaceTermination {
        .init(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didTerminateApplicationNotification, handler: handler)
    }
    static func processIdentifier(_ notification: Notification) -> Int32? {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return nil }
        return RunningApplicationPID.resolve(application)
    }
    func cancel() {
        let previous = lock.withLock { let previous = token; token = nil; return previous }
        if let previous { center.removeObserver(previous) }
    }
    deinit { cancel() }
}

/// Weak NSHashTable ownership, protected by one lock. No PID dedup.
final class ControllerOwnerWeakRegistry: @unchecked Sendable {
    static let shared = ControllerOwnerWeakRegistry()
    private let lock = NSLock()
    private let objects = NSHashTable<AnyObject>.weakObjects()
    func add(_ object: AnyObject) { lock.withLock { objects.add(object) } }
    func allObjects() -> [AnyObject] { lock.withLock { objects.allObjects } }
}

protocol ControllerOwnerOrdering: AnyObject, Sendable {
    var observedWindowIDs: [UInt32] { get set }
    func start()
    func stop()
    func menuDidOpen()
    func menuDidClose()
}
extension ControllerWindowOrdering: ControllerOwnerOrdering {}

protocol ControllerOwnerAXObservation<Node>: AnyObject, Sendable {
    associatedtype Node: Sendable
    func registerDestroyed(_ node: Node) throws
    func removeDestroyed(_ node: Node) throws
}
extension ControllerAXNotificationRegistration: ControllerOwnerAXObservation {
    func registerDestroyed(_ node: Node) throws { try register("AXUIElementDestroyed", for: node) }
    func removeDestroyed(_ node: Node) throws { try remove("AXUIElementDestroyed", for: node) }
}
