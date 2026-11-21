import AppKit
import ApplicationServices
import Foundation

/// AX returns immutable CF values. This bridge preserves the returned object,
/// including NSNull and AXValue error markers; it does not mutate those objects.
struct ControllerNativeAXValue: @unchecked Sendable { let raw: AnyObject }

enum ControllerNativeElementDecoding {
    enum Failure: Error { case accessibility(Int32), typeMismatch, missingResponse, shortResponse }
    static func element(_ value: ControllerNativeAXValue, strict: Bool) throws -> SettingsNativeAXElement? {
        if CFGetTypeID(value.raw) == AXUIElementGetTypeID() {
            return .init(element: unsafeDowncast(value.raw, to: AXUIElement.self))
        }
        try reject(value, strict: strict)
        return nil
    }
    static func elements(_ value: ControllerNativeAXValue, strict: Bool) throws -> [SettingsNativeAXElement]? {
        if CFGetTypeID(value.raw) == CFArrayGetTypeID(), let array = value.raw as? [AnyObject] {
            // compactMap calls the nonthrowing unwrapped helper for each
            // member; malformed/error members are dropped, preserving duplicates.
            return array.compactMap { try? element(.init(raw: $0), strict: false) }
        }
        try reject(value, strict: strict)
        return nil
    }
    private static func reject(_ value: ControllerNativeAXValue, strict: Bool) throws {
        guard strict else { return }
        if CFGetTypeID(value.raw) == AXValueGetTypeID() {
            let native = unsafeDowncast(value.raw, to: AXValue.self)
            if AXValueGetType(native) == .axError {
                var error = AXError.success
                _ = AXValueGetValue(native, .axError, &error)
                if error == .noValue { return }
                throw Failure.accessibility(error.rawValue)
            }
        }
        throw Failure.typeMismatch
    }
    static func batch(names: [String], response: [AnyObject]) throws -> [String: ControllerNativeAXValue] {
        guard response.count >= names.count else { throw Failure.shortResponse }
        var values: [String: ControllerNativeAXValue] = [:]
        for (index, name) in names.enumerated() {
            let value = response[index]
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let native = unsafeDowncast(value, to: AXValue.self)
                if AXValueGetType(native) == .axError {
                    var error = AXError.success
                    _ = AXValueGetValue(native, .axError, &error)
                    if ![AXError.success, .noValue, .attributeUnsupported].contains(error) {
                        values.removeValue(forKey: name); continue
                    }
                }
            }
            values[name] = .init(raw: value)
        }
        return values
    }
}

/// The root transaction is immutable and its fallback storage is locked.
/// This view keeps that owner alive while converting only key/value wrappers.
private final class ControllerRootSnapshotView<Key: Hashable & Sendable>: @unchecked Sendable {
    let transaction: EventStreamSnapshotTransaction<Key, AnyObject>
    init(_ transaction: EventStreamSnapshotTransaction<Key, AnyObject>) { self.transaction = transaction }
}

extension ControllerElementTransaction where Key == SettingsNativeAXElement, Value == ControllerNativeAXValue {
    static func bridged<RootKey: Hashable & Sendable>(_ source: EventStreamSnapshotTransaction<RootKey, AnyObject>,
        rootKey: @escaping @Sendable (Key) -> RootKey) -> Self {
        let owner = ControllerRootSnapshotView(source)
        return .init(requested: source.requestedAttributes, fallback: .init(read: { key in
            guard let value = owner.transaction.fallbackCache.snapshot(for: rootKey(key)) else { return nil }
            return .init(supported: value.supportedAttributes, values: value.attributes.mapValues { Value(raw: $0) }, requested: value.transactionAttributes)
        }, write: { value, key in
            owner.transaction.fallbackCache.store(.init(supportedAttributes: value.supported,
                attributes: value.values.mapValues(\.raw), transactionAttributes: value.requested), for: rootKey(key))
        }), lookup: { key in
            // Convert only this entry. Rebuilding the entire AX table on each
            // wrapper would turn a tree traversal into quadratic work.
            owner.transaction.attributeTable[rootKey(key)]?.mapValues { Value(raw: $0) }
        })
    }
}

/// Required bridged lookup distinguishes an absent node from a present node
/// with a nil bundle or zero/negative cached identities. Binding the global tree
/// owner to this lookup remains a factory responsibility.
struct ControllerNativeElementContext: Sendable {
    typealias Context = ControllerElementContext<SettingsNativeAXElement, ControllerNativeAXValue>
    typealias Node = Context.Node
    struct CachedIdentity: Sendable { let actualPID: Int32; let windowID: UInt32; let bundleIdentifier: String? }
    let currentTransaction: @Sendable () -> Context.Transaction?
    let lookup: @Sendable (SettingsNativeAXElement) -> CachedIdentity?
    let log: @Sendable (String, any Error) -> Void
    /// One I/O policy serves snapshot capture and later uncached reads. A
    /// hosted provider must be installed before creating wrappers.
    struct IO: Sendable {
        let supported: @Sendable (SettingsNativeAXElement) -> Set<String>
        let batch: @Sendable (SettingsNativeAXElement, Set<String>) throws -> [String: ControllerNativeAXValue]
        let read: @Sendable (SettingsNativeAXElement, String) throws -> ControllerNativeAXValue?
    }
    var io: IO? = nil

    var identity: ControllerAXIdentityReader<SettingsNativeAXElement> {
        .native { key in lookup(key).map { .init(actualPID: $0.actualPID, windowID: $0.windowID) } }
    }
    var context: Context {
        let inputs = io ?? .native
        return .init(environment: .init(currentTransaction: currentTransaction,
            supported: inputs.supported, bundleIdentifier: { key in
                if let cached = lookup(key) { return cached.bundleIdentifier }
                var pid: pid_t = -1
                guard AXUIElementGetPid(key.element, &pid) == .success else { return nil }
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }, batch: inputs.batch, read: inputs.read,
            decodeElement: { try ControllerNativeElementDecoding.element($0, strict: $1) },
            decodeElements: { try ControllerNativeElementDecoding.elements($0, strict: $1) },
            decodeString: { $0.raw as? String }, log: log))
    }
    func application(_ pid: Int32) -> Node { context.node(.init(element: AXUIElementCreateApplication(pid))) }
    func observe(pid: Int32, application: Node,
                 handler: @escaping @Sendable (Node, String) -> Void) throws -> any ControllerOwnerAXObservation<Node> {
        try ControllerContextAXObservation(pid: pid, application: application.element, context: context, handler: handler)
    }
}

/// Raw AX notifications construct their wrapper in the callback's current
/// TaskLocal context, rather than reusing the application wrapper's snapshot.
private final class ControllerContextAXObservation: ControllerOwnerAXObservation, @unchecked Sendable {
    typealias Node = ControllerNativeElementContext.Node
    private let observation: ControllerAXNotificationRegistration<ControllerAXNativeObserver, SettingsNativeAXElement>
    init(pid: Int32, application: SettingsNativeAXElement, context: ControllerNativeElementContext.Context,
         handler: @escaping @Sendable (Node, String) -> Void) throws {
        observation = try .init(pid: pid, application: application, environment: .native,
            handler: { handler(context.node($0), $1) })
    }
    func registerDestroyed(_ node: Node) throws { try observation.registerDestroyed(node.element) }
    func removeDestroyed(_ node: Node) throws { try observation.removeDestroyed(node.element) }
}


extension ControllerNativeElementContext.IO {
    static var native: Self {
        .init(supported: { key in
            var names: CFArray?
            _ = AXUIElementCopyAttributeNames(key.element, &names)
            return Set((names as? [String]) ?? [])
        }, batch: { key, attributes in
            let names = Array(attributes)
            var response: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(key.element, names as CFArray, [], &response)
            guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
            guard let response = response as? [AnyObject] else { throw ControllerNativeElementDecoding.Failure.missingResponse }
            return try ControllerNativeElementDecoding.batch(names: names, response: response)
        }, read: { key, name in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(key.element, name as CFString, &value)
            guard status == .success || status == .noValue || status == .attributeUnsupported else {
                throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue)
            }
            return value.map { .init(raw: $0) }
        })
    }
}
