import Foundation

struct ControllerElementSnapshot<Value: Sendable>: Sendable {
    let supported: Set<String>
    let values: [String: Value]
    let requested: Set<String>?
}

/// The fallback collector locks only cache access. Native work is outside the lock;
/// two simultaneous misses may capture independently, and the last store wins.
final class ControllerElementFallbackCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: ControllerElementSnapshot<Value>] = [:]
    private let readThrough: (@Sendable (Key) -> ControllerElementSnapshot<Value>?)?
    private let writeThrough: (@Sendable (ControllerElementSnapshot<Value>, Key) -> Void)?
    init() { readThrough = nil; writeThrough = nil }
    init(read: @escaping @Sendable (Key) -> ControllerElementSnapshot<Value>?,
         write: @escaping @Sendable (ControllerElementSnapshot<Value>, Key) -> Void) {
        readThrough = read; writeThrough = write
    }
    func get(_ key: Key) -> ControllerElementSnapshot<Value>? {
        if let readThrough { return readThrough(key) }
        return lock.withLock { entries[key] }
    }
    func store(_ snapshot: ControllerElementSnapshot<Value>, for key: Key) {
        if let writeThrough { writeThrough(snapshot, key); return }
        lock.withLock { entries[key] = snapshot }
    }
}

struct ControllerElementTransaction<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let table: [Key: [String: Value]]
    private let lookup: (@Sendable (Key) -> [String: Value]?)?
    let requested: Set<String>
    let fallback: ControllerElementFallbackCache<Key, Value>
    init(table: [Key: [String: Value]] = [:], requested: Set<String> = [],
         fallback: ControllerElementFallbackCache<Key, Value> = .init(),
         lookup: (@Sendable (Key) -> [String: Value]?)? = nil) {
        self.table = table; self.requested = requested; self.fallback = fallback; self.lookup = lookup
    }
    func values(for key: Key) -> [String: Value]? {
        if let lookup { return lookup(key) }
        return table[key]
    }
}

struct ControllerElementNode<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    let element: Key
    let snapshot: ControllerElementSnapshot<Value>
}

/// No actor hop: wrapper constructors capture the TaskLocal at construction,
/// including wrappers constructed by a later attribute read on the AX worker.
struct ControllerElementContext<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    typealias Node = ControllerElementNode<Key, Value>
    typealias Transaction = ControllerElementTransaction<Key, Value>
    struct Environment: Sendable {
        let currentTransaction: @Sendable () -> Transaction?
        let supported: @Sendable (Key) -> Set<String>
        let bundleIdentifier: @Sendable (Key) -> String?
        let batch: @Sendable (Key, Set<String>) throws -> [String: Value]
        let read: @Sendable (Key, String) throws -> Value?
        let decodeElement: @Sendable (Value, Bool) throws -> Key?
        let decodeElements: @Sendable (Value, Bool) throws -> [Key]?
        let decodeString: @Sendable (Value) -> String?
        let log: @Sendable (String, any Error) -> Void
    }
    let environment: Environment

    func node(_ element: Key) -> Node {
        let transaction = environment.currentTransaction()
        if let transaction, let values = transaction.values(for: element) {
            return .init(element: element, snapshot: .init(supported: Set(values.keys), values: values, requested: transaction.requested))
        }
        if let cached = transaction?.fallback.get(element) { return .init(element: element, snapshot: cached) }
        let supported = environment.supported(element)
        let selected = EventStreamSnapshotAttributes.selected(from: supported) { environment.bundleIdentifier(element) }
        let values = selected.isEmpty ? [:] : ((try? environment.batch(element, selected)) ?? [:])
        let snapshot = ControllerElementSnapshot(supported: supported, values: values, requested: nil)
        transaction?.fallback.store(snapshot, for: element)
        return .init(element: element, snapshot: snapshot)
    }
    func role(_ node: Node) -> String {
        node.snapshot.values["AXRole"].flatMap(environment.decodeString) ?? "AXUnknown"
    }
    private func mayRead(_ name: String, _ node: Node) -> Bool {
        EventStreamAttributeAvailability.mayRead(name, supported: node.snapshot.supported, requested: node.snapshot.requested)
    }
    private func window(_ name: String, _ application: Node) -> Node? {
        if let cached = application.snapshot.values[name], let key = try? environment.decodeElement(cached, false) {
            return node(key)
        }
        guard mayRead(name, application) else { return nil }
        do {
            guard let value = try environment.read(application.element, name),
                  let key = try environment.decodeElement(value, true) else { return nil }
            return node(key)
        } catch { environment.log(name, error); return nil }
    }
    func focusedWindow(_ application: Node) -> Node? { window("AXFocusedWindow", application) }
    func mainWindow(_ application: Node) -> Node? { window("AXMainWindow", application) }
    func windows(_ application: Node) -> [Node] {
        let name = "AXWindows"
        if let cached = application.snapshot.values[name], let keys = try? environment.decodeElements(cached, false) {
            return keys.map(node)
        }
        guard mayRead(name, application) else { return [] }
        let value: Value?
        do { value = try environment.read(application.element, name) }
        catch { environment.log(name, error); return [] }
        // Unlike focused/main, the specialized windows getter suppresses a
        // decoding failure without logging. Array member failures are dropped.
        guard let value, let keys = try? environment.decodeElements(value, false) else { return [] }
        return keys.map(node)
    }
    func primaryWindow(_ application: Node) -> Node? {
        focusedWindow(application) ?? mainWindow(application) ?? windows(application).last
    }
    func children(_ parent: Node) -> [Node] {
        let name = "AXChildren"
        if let cached = parent.snapshot.values[name], let keys = try? environment.decodeElements(cached, false) {
            return keys.map(node)
        }
        guard mayRead(name, parent) else { return [] }
        do {
            guard let value = try environment.read(parent.element, name),
                  let keys = try environment.decodeElements(value, true) else { return [] }
            return keys.map(node)
        } catch { environment.log(name, error); return [] }
    }
}
