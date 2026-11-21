import Foundation

struct EventStreamElementSnapshot<Value> {
    let supportedAttributes: Set<String>
    let attributes: [String:Value]
    let transactionAttributes: Set<String>?
}

// The fallback cache is shared by transaction copies. Native reads happen
// outside its lock; concurrent misses may both capture.
final class EventStreamSnapshotFallbackCache<Key: Hashable, Value> {
    private let lock = NSLock()
    private var snapshots: [Key:EventStreamElementSnapshot<Value>] = [:]
    private let readThrough: ((Key) -> EventStreamElementSnapshot<Value>?)?
    private let writeThrough: ((EventStreamElementSnapshot<Value>, Key) -> Void)?
    private let clearThrough: (() -> Void)?
    init() { readThrough = nil; writeThrough = nil; clearThrough = nil }
    fileprivate init(read: @escaping (Key) -> EventStreamElementSnapshot<Value>?,
                     write: @escaping (EventStreamElementSnapshot<Value>, Key) -> Void,
                     clear: @escaping () -> Void) {
        readThrough = read; writeThrough = write; clearThrough = clear
    }
    func snapshot(for key: Key) -> EventStreamElementSnapshot<Value>? {
        if let readThrough { return readThrough(key) }
        lock.lock();defer {lock.unlock()};return snapshots[key]
    }
    func store(_ snapshot: EventStreamElementSnapshot<Value>, for key: Key) {
        if let writeThrough { writeThrough(snapshot, key); return }
        lock.lock();defer {lock.unlock()};snapshots[key]=snapshot
    }
    func clear() {
        if let clearThrough { clearThrough(); return }
        lock.lock();defer {lock.unlock()};snapshots.removeAll()
    }
}

struct EventStreamSnapshotTransaction<Key: Hashable, Value> {
    let attributeTable: [Key:[String:Value]]
    let requestedAttributes: Set<String>
    let fallbackCache: EventStreamSnapshotFallbackCache<Key,Value>
    init(attributeTable: [Key:[String:Value]] = [:], requestedAttributes: Set<String> = [],
         fallbackCache: EventStreamSnapshotFallbackCache<Key,Value> = .init()) {
        self.attributeTable=attributeTable;self.requestedAttributes=requestedAttributes;self.fallbackCache=fallbackCache
    }
    /// Views of the same native AX identities must share fallback storage too.
    /// Rebuilding a dictionary alone would silently introduce a second cache.
    func rekey<Other: Hashable>(_ forward: (Key) -> Other,
                               reverse: @escaping (Other) -> Key) -> EventStreamSnapshotTransaction<Other, Value> {
        let cache = fallbackCache
        return .init(attributeTable: Dictionary(uniqueKeysWithValues: attributeTable.map { (forward($0.key), $0.value) }),
            requestedAttributes: requestedAttributes,
            fallbackCache: .init(read: { cache.snapshot(for: reverse($0)) },
                write: { cache.store($0, for: reverse($1)) }, clear: { cache.clear() }))
    }
}

enum EventStreamSnapshotAttributes {
    // All twenty common attributes, intersected with supported.
    static let common: Set<String> = [
        "AXRole","AXSubrole","AXRoleDescription","AXTitle","AXDescription",
        "AXValue","AXValueDescription","AXPlaceholderValue","AXNumberOfCharacters",
        "AXHelp","AXIdentifier","AXSelected","AXFocused","AXEnabled","AXDisclosing",
        "AXURL","AXTraits","AXServesAsTitleForUIElements","AXRowIndexRange","AXColumnIndexRange"
    ]
    static func selected(from supported: Set<String>, bundleIdentifier: () -> String?) -> Set<String> {
        var selected = supported.intersection(common)
        // Matching against the static attribute list is exact and occurs
        // only if this attribute was advertised; no identity lookup otherwise.
        if supported.contains("AXDOMClassList"), bundleIdentifier() == "com.kishanbagaria.jack" {
            selected.insert("AXDOMClassList")
        }
        selected.formUnion(supported.intersection([
            "AXVisibleRows","AXVisibleChildren","AXSelectedRows","AXSelectedCells","AXSelectedChildren"
        ]))
        return selected
    }
}

@MainActor protocol EventStreamSnapshotBackend {
    associatedtype Element: Hashable
    associatedtype Value
    func supportedAttributes(of element: Element) -> Set<String>
    func bundleIdentifier(of element: Element) -> String?
    func values(of element: Element, for attributes: Set<String>) throws -> [String:Value]
}

@MainActor struct EventStreamElementSnapshots<Backend: EventStreamSnapshotBackend> {
    let backend: Backend
    // Collector: a supplied transaction table has precedence over
    // its fallback cache. Even a present empty table entry is authoritative.
    func capture(_ element: Backend.Element,
                 transaction: EventStreamSnapshotTransaction<Backend.Element,Backend.Value>? = nil) -> EventStreamElementSnapshot<Backend.Value> {
        if let transaction, let values = transaction.attributeTable[element] {
            return .init(supportedAttributes:Set(values.keys),attributes:values,
                         transactionAttributes:transaction.requestedAttributes)
        }
        if let cached = transaction?.fallbackCache.snapshot(for:element) { return cached }
        let supported = backend.supportedAttributes(of:element)
        let selected = EventStreamSnapshotAttributes.selected(from:supported) { backend.bundleIdentifier(of:element) }
        // Batch failure is retained as a supported-but-empty fallback snapshot;
        // it is not retried until the transaction/cache owner replaces it.
        let values = selected.isEmpty ? [:] : ((try? backend.values(of:element,for:selected)) ?? [:])
        let snapshot = EventStreamElementSnapshot(supportedAttributes:supported,attributes:values,transactionAttributes:nil)
        transaction?.fallbackCache.store(snapshot,for:element)
        return snapshot
    }
}
