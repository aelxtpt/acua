import Foundation

/// WindowServer event types and their raw values.
enum ControllerWindowServerEvent: UInt32, CaseIterable, Sendable {
    case isObscured = 800, isUnobscured, isOrderedIn, isOrderedOut
    case isTerminated, isChangingScreens, didMove, didResize
    case didChangeOrder, geometryDidChange, monitorDataPending, didCreate
    case rightsGrantOffered, rightsGrantCompleted, recordForTermination
    case isVisible, isInvisible
    case workspaceAddWindow = 1325, workspaceRemoveWindow, workspaceCreated, workspaceDestroyed
}

/// Entries hold an immutable construction-time fallback cache.
/// Native registration owns event filtering; the dispatcher has no membership filter.
final class ControllerWindowEventRegistry<Window: Sendable>: @unchecked Sendable {
    typealias Handler = @Sendable (Window, ControllerWindowServerEvent) -> Void
    private struct Entry {
        let fallback: [UInt32: Window]
        let handler: Handler
    }
    private let lock = NSLock()
    private var lastToken: UInt = 0
    private var entries: [UInt: Entry] = [:]
    private let lookup: @Sendable (UInt32) -> Window?

    init(lookup: @escaping @Sendable (UInt32) -> Window?) { self.lookup = lookup }

    func window(for id: UInt32) -> Window? { id == 0 ? nil : lookup(id) }

    func insert(windowIDs: [UInt32], handler: @escaping Handler) -> UInt {
        var fallback: [UInt32: Window] = [:]
        // Preserve duplicates and lookup order. A later miss removes an earlier hit.
        for id in windowIDs { fallback[id] = window(for: id) }
        return lock.withLock {
            lastToken += 1
            entries[lastToken] = Entry(fallback: fallback, handler: handler)
            return lastToken
        }
    }

    func remove(_ token: UInt) {
        let removed = lock.withLock { entries.removeValue(forKey: token) }
        withExtendedLifetime(removed) {}
    }

    func deliver(rawEvent: UInt32, windowID: UInt32, token: UInt) {
        guard let event = ControllerWindowServerEvent(rawValue: rawEvent), token != 0 else { return }
        // Retain the callback/cache snapshot before unlocking.
        guard let entry = lock.withLock({ entries[token] }) else { return }
        guard let window = window(for: windowID) ?? entry.fallback[windowID] else { return }
        entry.handler(window, event)
    }

    /// The context moves over the length argument; delivery reads the first word.
    /// The native ABI requires readable, aligned UInt32 storage, regardless of length.
    func deliver(rawEvent: UInt32, payload: UnsafeRawPointer?, byteCount: Int, token: UInt) {
        guard ControllerWindowServerEvent(rawValue: rawEvent) != nil,
              let payload, token != 0 else { return }
        deliver(rawEvent: rawEvent, windowID: payload.load(as: UInt32.self), token: token)
    }
}

/// Native entry points remain injected until shared connection
/// ownership is bound. This component never opens a WindowServer connection itself.
final class ControllerWindowEventObserver<Window: Sendable>: @unchecked Sendable {
    struct Environment: Sendable {
        let registry: ControllerWindowEventRegistry<Window>
        let connectionID: @Sendable () -> Int32
        let register: @Sendable (Int32, ControllerWindowServerEvent, UInt) -> Int32
        let unregister: @Sendable (Int32, ControllerWindowServerEvent, UInt) -> Int32
        let request: @Sendable (Int32, [UInt32]) -> Int32
    }
    private let environment: Environment
    private let events: [ControllerWindowServerEvent]
    let token: UInt

    init(windowIDs: [UInt32], events: [ControllerWindowServerEvent], environment: Environment,
         handler: @escaping ControllerWindowEventRegistry<Window>.Handler) {
        self.environment = environment
        self.events = events
        token = environment.registry.insert(windowIDs: windowIDs, handler: handler)
        let connection = environment.connectionID()
        for event in events { _ = environment.register(connection, event, token) }
        _ = environment.request(connection, windowIDs)
    }

    deinit {
        environment.registry.remove(token)
        let connection = environment.connectionID()
        for event in events { _ = environment.unregister(connection, event, token) }
        // The notification request is not reset here.
    }
}
