import AppKit
import ApplicationServices
import Darwin

struct LockScreenAXIdentity: Hashable {
    let element: AXUIElement
    static func == (a: Self,b: Self) -> Bool { CFEqual(a.element,b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
struct LockScreenNativeAXNode {
    let element: AXUIElement
    let snapshot: EventStreamElementSnapshot<AnyObject>
}

@MainActor private struct LockScreenAXSnapshotBackend: EventStreamSnapshotBackend {
    typealias Element = LockScreenAXIdentity
    typealias Value = AnyObject
    enum Error: Swift.Error { case read(Int32), response }
    func supportedAttributes(of node: Element) -> Set<String> {
        var names: CFArray?
        _ = AXUIElementCopyAttributeNames(node.element,&names)
        return Set((names as? [String]) ?? [])
    }
    func bundleIdentifier(of node: Element) -> String? {
        var pid: Int32 = 0
        guard AXUIElementGetPid(node.element,&pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier:pid)?.bundleIdentifier
    }
    func values(of node: Element,for attributes: Set<String>) throws -> [String:AnyObject] {
        let names = Array(attributes)
        var response: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(node.element,names as CFArray,[],&response)
        guard status == .success else { throw Error.read(status.rawValue) }
        guard let values = response as? [AnyObject], values.count >= names.count else { throw Error.response }
        var result = [String:AnyObject]()
        for (name,value) in zip(names,values) {
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let encoded = unsafeDowncast(value,to:AXValue.self)
                if AXValueGetType(encoded) == .axError {
                    var error = AXError.success
                    _ = AXValueGetValue(encoded,.axError,&error)
                    if ![AXError.success,.noValue,.attributeUnsupported].contains(error) { result[name] = nil; continue }
                }
            }
            result[name] = value
        }
        return result
    }
}

@MainActor final class LockScreenNativeAXBackend: LockScreenAXBackend {
    typealias Node = LockScreenNativeAXNode
    typealias Batch = [CGEvent]
    typealias Transaction = EventStreamSnapshotTransaction<LockScreenAXIdentity,AnyObject>
    enum Error: Swift.Error { case accessibility(Int32), unavailable }
    private let processes: LockScreenLoginProcessLookup
    private let events: LockScreenNativeEvents
    private let transaction: () -> Transaction?
    private typealias GetWindow = @convention(c) (AXUIElement,UnsafeMutablePointer<UInt32>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",RTLD_LAZY | RTLD_LOCAL) else { return nil }
        for name in ["AXUIElementGetWindow","_AXUIElementGetWindow"] {
            if let symbol = dlsym(image,name) { return unsafeBitCast(symbol,to:GetWindow.self) }
        }
        return nil
    }()

    init(nextEventNumber: @escaping () -> Int64, processes: LockScreenLoginProcessLookup = .native,
         transaction: @escaping () -> Transaction? = { nil }) {
        self.processes = processes; events = .init(nextEventNumber:nextEventNumber); self.transaction = transaction
    }
    private func node(_ element: AXUIElement) -> Node {
        let snapshot = EventStreamElementSnapshots(backend:LockScreenAXSnapshotBackend()).capture(.init(element:element),transaction:transaction())
        return .init(element:element,snapshot:snapshot)
    }
    private func attributes(_ node: Node) -> LockScreenAXAttributeValues {
        .init(cached:node.snapshot.attributes,supported:node.snapshot.supportedAttributes,
              requested:node.snapshot.transactionAttributes,read:{ name in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(node.element,name as CFString,&value) == .success ? value : nil
        })
    }
    func loginApplication() -> Node? { processes.processIdentifier().map { node(AXUIElementCreateApplication($0)) } }
    func children(_ node: Node) -> [Node] {
        func decode(_ raw: AnyObject?) -> [AXUIElement]? {
            guard let raw, CFGetTypeID(raw) == CFArrayGetTypeID(), let list = raw as? [AnyObject],
                  list.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return list.map { unsafeDowncast($0,to:AXUIElement.self) }
        }
        let children = attributes(node).value("AXChildren",decode:decode) ?? []
        return children.map(self.node)
    }
    func identifier(_ node: Node) -> String? { attributes(node).string("AXIdentifier") }
    func role(_ node: Node) -> String? { attributes(node).string("AXRole") ?? "AXUnknown" }
    func value(_ node: Node) -> String? { attributes(node).string("AXValue") }
    func isEnabled(_ node: Node) -> Bool { attributes(node).isEnabled }
    func frame(_ node: Node) -> CGRect? { attributes(node).frame }
    func window(_ node: Node) -> Node? {
        func decode(_ raw: AnyObject?) -> AXUIElement? {
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw,to:AXUIElement.self)
        }
        return attributes(node).value("AXWindow",decode:decode).map(self.node)
    }
    func windowID(_ node: Node) throws -> UInt32 {
        guard let get = Self.getWindow else { throw Error.unavailable }
        var id: UInt32 = 0
        let status = get(node.element,&id)
        guard status == .success else { throw Error.accessibility(status.rawValue) }
        // Accept window ID 0 when the SPI itself succeeds.
        return id
    }
    func setEmptyValue(_ node: Node) throws {
        let error = AXUIElementSetAttributeValue(node.element,"AXValue" as CFString,"" as CFString)
        guard error == .success else { throw Error.accessibility(error.rawValue) }
    }
    func makeClick(_ click: LockScreenRevealClick) throws -> [CGEvent] { try events.makeClick(click) }
    func makeReturn() async throws -> [CGEvent] { try events.makeReturn() }
    func send(_ batch: [CGEvent]) async throws { events.send(batch) }

}
