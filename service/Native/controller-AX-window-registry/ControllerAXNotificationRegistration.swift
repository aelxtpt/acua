import ApplicationServices
import Foundation

/// AX notification observer: per-name element sets and strict status
/// handling, with creation/registration before the user-initiated worker starts.
final class ControllerAXNotificationRegistration<Handle: Sendable, Node: Hashable & Sendable>: @unchecked Sendable {
    struct Failure: Error { let status: Int32 }
    struct Environment: Sendable {
        let create: @Sendable (Int32, @escaping @Sendable (Node, String, CFDictionary?) -> Void) throws -> Handle
        let add: @Sendable (Handle, Node, String) -> Int32
        let remove: @Sendable (Handle, Node, String) -> Int32
        let start: @Sendable (Handle, QualityOfService) -> Void
        let stop: @Sendable (Handle) -> Void
    }
    private final class Callback: @unchecked Sendable {
        weak var owner: ControllerAXNotificationRegistration?
        let handler: @Sendable (Node, String) -> Void
        init(_ handler: @escaping @Sendable (Node, String) -> Void) { self.handler = handler }
        func receive(_ node: Node, _ name: String, _ info: CFDictionary?) {
            guard info == nil || info as? [String: AnyObject] != nil, let owner else { return }
            withExtendedLifetime(owner) { handler(node, name) }
        }
    }
    let handle: Handle
    private let environment: Environment
    private let lock = NSLock()
    private var registered: [String: Set<Node>] = [:]
    static var controllerNotifications: [String] {
        ["AXWindowCreated", "AXMenuOpened", "AXMenuClosed", "AXSheetCreated", "AXMoved", "AXResized"]
    }
    init(pid: Int32, application: Node, environment: Environment,
         handler: @escaping @Sendable (Node, String) -> Void) throws {
        self.environment = environment
        let callback = Callback(handler)
        handle = try environment.create(pid) { callback.receive($0, $1, $2) }
        callback.owner = self
        for name in Self.controllerNotifications { try register(name, for: application) }
        environment.start(handle, .userInitiated)
    }
    func snapshot() -> [String: Set<Node>] { lock.withLock { registered } }
    func register(_ name: String, for node: Node, ignoring: [Int32] = []) throws {
        let status = environment.add(handle, node, name)
        if ignoring.contains(status) { return }
        guard status == 0 || status == AXError.notificationAlreadyRegistered.rawValue else { throw Failure(status: status) }
        _ = lock.withLock { registered[name, default: []].insert(node) }
    }
    func remove(_ name: String, for node: Node) throws {
        let status = environment.remove(handle, node, name)
        guard status == 0 || status == AXError.notificationNotRegistered.rawValue else { throw Failure(status: status) }
        _ = lock.withLock { registered[name, default: []].remove(node) }
    }
    func stop() { environment.stop(handle) }
    deinit { environment.stop(handle) }
}
