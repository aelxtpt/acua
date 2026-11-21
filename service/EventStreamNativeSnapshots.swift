import AppKit
import ApplicationServices

struct EventStreamSnapshotAXIdentity: Hashable {
    let element: AXUIElement
    static func == (lhs:Self,rhs:Self) -> Bool { CFEqual(lhs.element,rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

@MainActor final class EventStreamNativeSnapshotBackend: EventStreamSnapshotBackend {
    typealias Element = EventStreamSnapshotAXIdentity
    typealias Value = AnyObject
    enum ReadError: Error { case accessibility(Int32), missingResponse, shortResponse }
    private let bridgedBundleIdentifier: ((AXUIElement) -> String?)?
    init(bridgedBundleIdentifier: ((AXUIElement) -> String?)? = nil) {
        self.bridgedBundleIdentifier=bridgedBundleIdentifier
    }
    func supportedAttributes(of element: Element) -> Set<String> {
        var names: CFArray?
        // supportedAttributes ignores the AX status and uses a valid returned
        // array when one is present.
        _ = AXUIElementCopyAttributeNames(element.element,&names)
        return Set((names as? [String]) ?? [])
    }
    func bundleIdentifier(of element: Element) -> String? {
        // A bridged identity with nil bundle does not borrow the native PID's
        // bundle; only an absent bridge uses NSRunningApplication.
        if let bridgedBundleIdentifier { return bridgedBundleIdentifier(element.element) }
        var pid: pid_t = -1
        guard AXUIElementGetPid(element.element,&pid) == .success else {return nil}
        return NSRunningApplication(processIdentifier:pid)?.bundleIdentifier
    }
    func values(of element: Element, for attributes: Set<String>) throws -> [String:AnyObject] {
        let names=Array(attributes)
        var response: CFArray?
        let error=AXUIElementCopyMultipleAttributeValues(element.element,names as CFArray,[],&response)
        guard error == .success else {throw ReadError.accessibility(error.rawValue)}
        guard let response=response as? [AnyObject] else {throw ReadError.missingResponse}
        return try Self.decode(names:names,response:response)
    }
    static func decode(names: [String], response: [AnyObject]) throws -> [String:AnyObject] {
        guard response.count >= names.count else {throw ReadError.shortResponse}
        var result: [String:AnyObject] = [:]
        // NSNull and AXValue error markers are retained for success,
        // noValue and attributeUnsupported. Other per-field errors remove the
        // entry, including an earlier duplicate. Excess response values ignored.
        for (index,name) in names.enumerated() {
            let value=response[index]
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let ax=unsafeBitCast(value,to:AXValue.self)
                if AXValueGetType(ax) == .axError {
                    var error=AXError.success
                    _ = AXValueGetValue(ax,.axError,&error)
                    if ![AXError.success,.noValue,.attributeUnsupported].contains(error) {
                        result.removeValue(forKey:name);continue
                    }
                }
            }
            result[name]=value
        }
        return result
    }
}

// Supplies snapshot-backed AX nodes to existing element/child readers. Native
// transformed-node construction and the complete transaction lifecycle are
// separate dependencies and are not replaced by these snapshots.
@MainActor final class EventStreamNativeSnapshots {
    typealias Transaction = EventStreamSnapshotTransaction<EventStreamSnapshotAXIdentity,AnyObject>
    let backend: EventStreamNativeSnapshotBackend
    init(backend: EventStreamNativeSnapshotBackend? = nil) { self.backend=backend ?? .init() }
    func capture(_ element: AXUIElement, transaction: Transaction? = nil) -> EventStreamElementSnapshot<AnyObject> {
        EventStreamElementSnapshots(backend:backend).capture(.init(element:element),transaction:transaction ?? EventStreamTreeTransactions.current?.snapshots)
    }
    func node(_ element: AXUIElement, transaction: Transaction? = nil) -> EventStreamAXNode {
        let tree = transaction == nil ? EventStreamTreeTransactions.current : nil
        return node(element,transaction:transaction ?? tree?.snapshots,tree:tree)
    }
    private func node(_ element:AXUIElement,transaction:Transaction?,tree:EventStreamNativeTreeTransaction?) -> EventStreamAXNode {
        let snapshot=EventStreamElementSnapshots(backend:backend).capture(.init(element:element),transaction:transaction)
        return .init(element,supportedAttributes:snapshot.supportedAttributes,
                     attributes:snapshot.attributes,transactionAttributes:snapshot.transactionAttributes,
                     partialValues:tree?.partialValues[.init(element:element)] ?? [:],
                     related:{[self] in node($0,transaction:transaction,tree:tree)})
    }
}
