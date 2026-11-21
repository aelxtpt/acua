import AppKit
import ApplicationServices
import Foundation

enum SelectionDataFailure: Error { case write, unexpected }
final class SelectionDataBridge: ControllerNativeElementValueBridge, ControllerNativeParameterizedValueBridge, @unchecked Sendable {
    var ordinaryPID: Int32 { 0 }; var actualPID: Int32 { 0 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    var parameters: [(String, ControllerNativeAXValue)] = []
    var returnedFrame: CGRect? = .init(x:10,y:20,width:30,height:40)
    var failParameter = false
    func parameterizedValue(_ attribute: String, parameter: ControllerNativeAXValue) throws -> ControllerNativeAXValue? {
        parameters.append((attribute,parameter))
        if failParameter { throw SelectionDataFailure.unexpected }
        guard var frame = returnedFrame else { return nil }
        return .init(raw: AXValueCreate(.cgRect,&frame)!)
    }
    var writes: [(String, ControllerNativeAXValue)] = []
    var reads: [String] = []
    var failWrite = false
    func supported() -> Set<String> { [] }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { throw SelectionDataFailure.unexpected }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { reads.append(attribute); throw SelectionDataFailure.unexpected }
    func perform(_ action: String) throws { throw SelectionDataFailure.unexpected }
    func actions() -> [String] { [] }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { attribute == "AXSelectedTextRange" }
    func setBoolean(_ attribute: String, _ value: Bool) throws { throw SelectionDataFailure.unexpected }
    func setValue(_ value: ControllerNativeAXValue, for attribute: String) throws {
        if failWrite { throw SelectionDataFailure.write }
        writes.append((attribute, value))
    }
}

@MainActor final class SelectionDataFixture {
    typealias Node = ControllerNativeRefetchIO.Node
    let raw = AXUIElementCreateSystemWide()
    let bridge = SelectionDataBridge()
    let resources: ControllerNativeResources
    var refreshes = 0
    var writesBeforeRefresh = false
    init() {
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in nil }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") },
            reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No input") })
        let provider = bridge
        resources = .init(context: context, lookup: { _ in provider }, windowServer: ws)
    }
    func handle(_ value: AnyObject?, role: String = "AXTextField", extra: [String: AnyObject] = [:]) throws -> ControllerNativeResolvedElement {
        var attributes = extra; attributes["AXRole"] = role as NSString; attributes["AXValue"] = value
        let base = EventStreamAXNode(raw, supportedAttributes: Set(attributes.keys), attributes: attributes,
            transactionAttributes: ["AXValue", "AXDateTimeComponents", "AXSelectedTextRange"])
        var node = Node(element: base); node.role = role; node.value = "before"
        let collected = EventStreamCollectedTree<EventStreamAXNode>(roots: [.init(node: node, path: [0], children: [], childrenSubset: nil)])
        let revision = try EventStreamNativeTreeRevision.Revision.root(collected, focusTree: nil,
            lineageID: UUID().uuidString, identity: { .init(element: $0.element) }, render: { tree in
                .init(isFocusTree: false, roots: tree.roots.map { .init(identity: .init(element: $0.node.element.element), text: "field", sourcePath: $0.path) })
            })
        let window = EventStreamNativeWindow(id: 51, processIdentifier: getpid(), frame: .init(x: 0, y: 0, width: 100, height: 100), level: 0, title: "data", ownerName: "owned")
        let contextual = ControllerNativeAppSnapshotContext.contextual(base)
        let source = ControllerNativeAppSnapshotSource(context: .init(application: base, window: base, focusedElement: nil, nativeWindow: window), window: contextual)
        let monitor = EventStreamTreeInvalidationMonitor(application: raw,
            io: .init(processIdentifier: { _ in throw SelectionDataFailure.unexpected }, observer: { _, _ in preconditionFailure("No AX observer") }))
        monitor.withState { $0.layoutChanged = true }
        let selection = ControllerNativeAppSnapshotSelection(.init(applicationWindow: .init(application: base, window: base, nativeWindow: window),
            windowRevision: revision, invalidationMonitor: monitor, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: source)
        let tree = ControllerRefetchableAppSnapshotTree(selection: selection, isAXTreeDiffingEnabled: true)
        let io = ControllerNativeRefetchIO(roleStatus: { _ in 0 }, fresh: { old in
            self.refreshes += 1; self.writesBeforeRefresh = !self.bridge.writes.isEmpty
            var fresh = old; fresh.value = "after"; return fresh
        }, capture: { _, _ in throw SelectionDataFailure.unexpected })
        return .init(node: node, tree: tree, resources: resources, io: io)
    }
}

