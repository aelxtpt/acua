import AppKit
import ApplicationServices
import Foundation
import ImageIO

private enum RefetchBindingError: Error { case observation, capture, write }
private final class ImageFailureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String, _ error: any Error) { lock.withLock { messages.append(message + ":" + String(describing: error)) } }
    var count: Int { lock.withLock { messages.count } }
}
@MainActor private final class RefetchNativeFixture {
    typealias Node = ControllerNativeRefetchIO.Node
    let raw = AXUIElementCreateSystemWide()
    let resources: ControllerNativeResources
    var captures = 0
    var probes = 0
    var freshReads = 0
    var status: Int32 = 0
    var failCapture = false
    var diff: Bool?
    var previous: ControllerNativeAppSnapshotSelection?
    var replacement: ControllerNativeAppSnapshotSelection?
    var refreshed: Node?
    init() {
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in nil }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") },
            reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No input") })
        resources = .init(context: context, lookup: { _ in nil }, windowServer: ws)
    }
    func node(_ serial: Int32, title: String = "same", value: String = "before") -> Node {
        var valueNode = Node(element: EventStreamAXNode(AXUIElementCreateApplication(serial), supportedAttributes: [], attributes: [:]))
        valueNode.role = "AXButton"; valueNode.title = title; valueNode.value = value
        return valueNode
    }
    func monitor(dirty: Bool) -> EventStreamTreeInvalidationMonitor {
        let result = EventStreamTreeInvalidationMonitor(application: raw,
            io: .init(processIdentifier: { _ in throw RefetchBindingError.observation }, observer: { _, _ in preconditionFailure("No AX observer") }))
        result.withState { $0.layoutChanged = dirty }
        return result
    }
    func selection(_ nodes: [Node], monitor: EventStreamTreeInvalidationMonitor?, focus: [Node]? = nil) throws -> ControllerNativeAppSnapshotSelection {
        func collected(_ nodes: [Node]) -> EventStreamCollectedTree<EventStreamAXNode> {
            .init(roots: nodes.enumerated().map { .init(node: $0.element, path: [$0.offset], children: [], childrenSubset: nil) })
        }
        let revision = try EventStreamNativeTreeRevision.Revision.root(collected(nodes), focusTree: focus.map(collected),
            lineageID: UUID().uuidString, identity: { .init(element: $0.element) }, render: { tree in
                .init(isFocusTree: false, roots: tree.roots.map { .init(identity: .init(element: $0.node.element.element), text: $0.node.title ?? "", sourcePath: $0.path) })
            })
        let base = EventStreamAXNode(raw, supportedAttributes: [], attributes: [:])
        let window = EventStreamNativeWindow(id: 51, processIdentifier: getpid(), frame: .init(x: 0, y: 0, width: 100, height: 100), level: 0, title: "data fixture", ownerName: "owned")
        let contextNode = ControllerNativeElementContext.Node(element: .init(element: raw), snapshot: .init(supported: [], values: [:], requested: nil))
        let source = ControllerNativeAppSnapshotSource(context: .init(application: base, window: base, focusedElement: nil, nativeWindow: window), window: contextNode)
        return .init(.init(applicationWindow: .init(application: base, window: base, nativeWindow: window), windowRevision: revision,
            invalidationMonitor: monitor, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: source)
    }
    func io() -> ControllerNativeRefetchIO {
        .init(roleStatus: { _ in self.probes += 1; return self.status }, fresh: { initial in self.freshReads += 1; return self.refreshed ?? initial },
            capture: { previous, diff in
                self.captures += 1; self.previous = previous; self.diff = diff
                if self.failCapture { throw RefetchBindingError.capture }
                return self.replacement!
            })
    }
    func backend(_ tree: ControllerRefetchableAppSnapshotTree) -> ControllerNativeElementRefetch { .init(tree: tree, resources: resources, io: io()) }
}

@MainActor enum NativeRefetchBindingChecks {
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        func isFailure(_ expected: ControllerElementRefetchFailure, _ work: () throws -> Void) -> Bool {
            do { try work(); return false } catch { return error as? ControllerElementRefetchFailure == expected }
        }
        for (label,leftRole,rightRole) in [("accent","é","e\u{301}"),("hangul","\u{AC00}","\u{1100}\u{1161}")] {
            for ignore in [false,true] {
                let f=RefetchNativeFixture();var initial=f.node(71001);initial.role=leftRole
                var fresh=f.node(71002);fresh.role=rightRole
                let old=try f.selection([initial],monitor:f.monitor(dirty:true))
                let new=try f.selection([fresh],monitor:f.monitor(dirty:false))
                let tree=ControllerRefetchableAppSnapshotTree(selection:old,isAXTreeDiffingEnabled:false)
                f.refreshed=fresh;f.replacement=new
                let h=ControllerNativeResolvedElement(node:initial,tree:tree,resources:f.resources,io:f.io())
                check("canonical role mismatch reaches full recovery \(label)/\(ignore)",isFailure(.unavailable(.missingAfterRefetch)) {try h.refetchIfNeeded(validateElement:true,ignoreValueChange:ignore)})
                check("canonical role mismatch performs one fresh read and recapture \(label)/\(ignore)",f.freshReads==1 && f.captures==1)
                check("canonical role mismatch preserves old handle and commits new selection \(label)/\(ignore)",CFEqual(h.node.element.element,initial.element.element) && tree.selection===new)
            }
        }
        do {
            let f=RefetchNativeFixture();let initial=f.node(71003,title:"é");let fresh=f.node(71004,title:"e\u{301}")
            let tree=ControllerRefetchableAppSnapshotTree(selection:try f.selection([initial],monitor:f.monitor(dirty:true)),isAXTreeDiffingEnabled:false)
            f.refreshed=fresh
            let h=ControllerNativeResolvedElement(node:initial,tree:tree,resources:f.resources,io:f.io())
            try h.refetchIfNeeded(validateElement:true,ignoreValueChange:false)
            check("canonical titles still recover without full recapture",CFEqual(h.node.element.element,fresh.element.element) && f.freshReads==1 && f.captures==0)
        }
        do {
            let f=RefetchNativeFixture();var initial=f.node(71005);initial.role="é"
            var fresh=f.node(71006);fresh.role="e\u{301}"
            let tree=ControllerRefetchableAppSnapshotTree(selection:try f.selection([initial],monitor:f.monitor(dirty:false)),isAXTreeDiffingEnabled:false)
            f.refreshed=fresh
            let h=try ControllerElementRefetch(backend:f.backend(tree)).resolve(initial,validateElement:true,ignoreValueChange:false)
            check("clean monitor still uses the cached fast path",CFEqual(h.node.element.element,initial.element.element) && f.freshReads==0 && f.captures==0 && f.probes==1)
        }
        do {
            let f = RefetchNativeFixture(); let node = f.node(70001)
            let s = try f.selection([node], monitor: nil); let tree = ControllerRefetchableAppSnapshotTree(selection: s, isAXTreeDiffingEnabled: true)
            let engine = ControllerElementRefetch(backend: f.backend(tree)); let id = s.value.windowRevision.renderTree.roots[0].elementID!
            check("actual revision ID resolves before missing monitor failure", isFailure(.unavailable(.missingMonitor)) { _ = try engine.resolve(id: id, validateElement: true) })
            check("unknown actual revision ID reports the requested numeric ID", isFailure(.missingID(-1)) { _ = try engine.resolve(id: -1, validateElement: true) })
            check("missing monitor performs no AX probe or recapture", f.probes == 0 && f.captures == 0)
        }
        do {
            let f = RefetchNativeFixture(); let node = f.node(70002); let monitor = f.monitor(dirty: false)
            let s = try f.selection([node], monitor: monitor); let tree = ControllerRefetchableAppSnapshotTree(selection: s, isAXTreeDiffingEnabled: false)
            let h = try ControllerElementRefetch(backend: f.backend(tree)).resolve(node, validateElement: true, ignoreValueChange: false)
            check("native adapter reads state despite monitor having no observer", !monitor.hasObserver && f.freshReads == 0 && f.probes == 1)
            check("resolved native handle retains the requested element and containing tree", CFEqual(h.node.element.element, node.element.element) && h.containingTree === tree)
            f.status = AXError.invalidUIElement.rawValue
            check("native invalid AX status is preserved", isFailure(.unavailable(.invalidElement)) { try h.refetchIfNeeded(validateElement: true, ignoreValueChange: false) })
            f.status = AXError.cannotComplete.rawValue
            try h.refetchIfNeeded(validateElement: true, ignoreValueChange: false)
            check("native non-invalid AX status retains source", CFEqual(h.node.element.element, node.element.element) && tree.selection === s)
        }
        do {
            let f = RefetchNativeFixture(); let initial = f.node(70003); let fresh = f.node(70004)
            let tree = ControllerRefetchableAppSnapshotTree(selection: try f.selection([initial], monitor: f.monitor(dirty: true)), isAXTreeDiffingEnabled: true)
            f.refreshed = fresh
            let h = ControllerNativeResolvedElement(node: initial, tree: tree, resources: f.resources, io: f.io())
            try h.refetchIfNeeded(validateElement: true, ignoreValueChange: false)
            check("native mutable handle adopts matching fresh element", CFEqual(h.node.element.element, fresh.element.element) && f.captures == 0 && f.probes == 0)
        }
        do {
            let f = RefetchNativeFixture(); let initial = f.node(70005); let refetched = f.node(70006)
            let old = try f.selection([initial], monitor: f.monitor(dirty: true), focus: [f.node(70007)])
            let new = try f.selection([refetched], monitor: f.monitor(dirty: false), focus: [f.node(70008)])
            let tree = ControllerRefetchableAppSnapshotTree(selection: old, isAXTreeDiffingEnabled: false)
            f.refreshed = f.node(70009, title: "changed"); f.replacement = new
            let h = ControllerNativeResolvedElement(node: initial, tree: tree, resources: f.resources, io: f.io())
            try h.refetchIfNeeded(validateElement: true, ignoreValueChange: false)
            check("native uniqueness scans main trees without duplicate focus matches", CFEqual(h.node.element.element, refetched.element.element) && f.captures == 1)
            check("native recapture passes existing selection and per-tree diff flag", f.previous === old && f.diff == false)
            check("native tree publishes successful recapture before adopting handle", tree.selection === new && h.containingTree === tree)
        }
        for duplicate in [false, true] {
            let f = RefetchNativeFixture(); let initial = f.node(70010)
            let old = try f.selection([initial], monitor: f.monitor(dirty: true))
            let new = try f.selection(duplicate ? [f.node(70011), f.node(70012)] : [], monitor: f.monitor(dirty: false))
            let tree = ControllerRefetchableAppSnapshotTree(selection: old, isAXTreeDiffingEnabled: true)
            f.refreshed = f.node(70013, title: "changed"); f.replacement = new
            let h = ControllerNativeResolvedElement(node: initial, tree: tree, resources: f.resources, io: f.io())
            check("native post-recapture \(duplicate ? "ambiguous" : "missing") keeps distinct reason",
                isFailure(.unavailable(duplicate ? .ambiguousAfterRefetch : .missingAfterRefetch)) { try h.refetchIfNeeded(validateElement: true, ignoreValueChange: false) })
            check("native failed final match preserves handle but commits new selection \(duplicate)", CFEqual(h.node.element.element, initial.element.element) && tree.selection === new)
        }
        do {
            let f = RefetchNativeFixture(); let initial = f.node(70014)
            let old = try f.selection([initial], monitor: f.monitor(dirty: true))
            let tree = ControllerRefetchableAppSnapshotTree(selection: old, isAXTreeDiffingEnabled: true)
            f.refreshed = f.node(70015, title: "changed"); f.failCapture = true
            let h = ControllerNativeResolvedElement(node: initial, tree: tree, resources: f.resources, io: f.io())
            var caught = false
            do { try h.refetchIfNeeded(validateElement: true, ignoreValueChange: false) } catch RefetchBindingError.capture { caught = true }
            check("native capture error preserves tree and mutable handle", caught && tree.selection === old && CFEqual(h.node.element.element, initial.element.element))
        }
        do {
            let f = RefetchNativeFixture(); let initial = f.node(70016)
            let tree = ControllerRefetchableAppSnapshotTree(selection: try f.selection([initial], monitor: f.monitor(dirty: true)), isAXTreeDiffingEnabled: true)
            f.refreshed = f.node(70017, value: "after")
            let h = ControllerNativeResolvedElement(node: initial, tree: tree, resources: f.resources, io: f.io())
            var wrote = false
            try h.afterWriting { node in wrote = CFEqual(node.element.element, initial.element.element) && f.freshReads == 0 }
            check("native setter writes first and admits changed value", wrote && h.node.value == "after" && f.freshReads == 1 && f.captures == 0)
            let before = f.freshReads; var caught = false
            do { try h.afterWriting { _ in throw RefetchBindingError.write } } catch RefetchBindingError.write { caught = true }
            check("failed native write performs no refresh", caught && f.freshReads == before && h.node.value == "after")
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-C99-generated-image-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = context.makeImage()!; let sink = ImageFailureSink()
            let file = try NativeAppSnapshotImage.write(image, appName: "Generated test image", directory: directory, encoding: .png)
            check("actual native encoder writes generated 2px image without screen capture", FileManager.default.fileExists(atPath: file.path) && CGImageSourceCreateWithURL(file as CFURL, nil) != nil)
            var first: ControllerTemporaryImage? = .adoptingNative(file, log: { sink.record($0, $1) })
            var second = first
            first = nil
            check("native image file survives while attachment reference is retained", second != nil && FileManager.default.fileExists(atPath: file.path))
            second = nil
            check("native image last reference deletes owned file without error", !FileManager.default.fileExists(atPath: file.path) && sink.count == 0)
            check("native image deletion removes legacy ownership registry entry", !NativeAppSnapshotImage.removeIfOwned(file))
            let missing = try NativeAppSnapshotImage.write(image, appName: "Removed before ARC", directory: directory, encoding: .png)
            var retained: ControllerTemporaryImage? = .adoptingNative(missing, log: { sink.record($0, $1) })
            try FileManager.default.removeItem(at: missing)
            check("image cleanup failure fixture holds native ARC object", retained != nil)
            retained = nil
            check("native image deletion failure reaches logging callback once", sink.count == 1)
            check("native failed deletion still relinquishes legacy ownership", !NativeAppSnapshotImage.removeIfOwned(missing))
        }
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "actual_native_data_adapters_executed": true, "native_AX_role_fresh_capture_IO_mocked": true,
            "actual_generated_raster_encode_and_ARC_cleanup": true, "native_AX_capture_focus_input_attention_cursor_window_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native refetch bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
