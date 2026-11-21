import AppKit
import ApplicationServices
import Foundation

private enum StringWriterFailure: Error { case write, unexpected }
private final class StringWriterBridge: ControllerNativeElementValueBridge, @unchecked Sendable {
    var ordinaryPID: Int32 { 0 }; var actualPID: Int32 { 0 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    var writes: [(String, ControllerNativeAXValue)] = []
    var reads: [String] = []
    var failWrite = false
    func supported() -> Set<String> { [] }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { throw StringWriterFailure.unexpected }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { reads.append(attribute); if attribute == "AXFocused" { return .init(raw: kCFBooleanTrue!) }; throw StringWriterFailure.unexpected }
    func perform(_ action: String) throws { throw StringWriterFailure.unexpected }
    func actions() -> [String] { [] }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { true }
    func setBoolean(_ attribute: String, _ value: Bool) throws { throw StringWriterFailure.unexpected }
    func setValue(_ value: ControllerNativeAXValue, for attribute: String) throws {
        if failWrite { throw StringWriterFailure.write }
        writes.append((attribute, value))
    }
}

@MainActor private final class StringWriterFixture {
    typealias Node = ControllerNativeRefetchIO.Node
    let raw = AXUIElementCreateSystemWide()
    let bridge = StringWriterBridge()
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
            transactionAttributes: ["AXValue", "AXDateTimeComponents", "AXFocused"])
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
            io: .init(processIdentifier: { _ in throw StringWriterFailure.unexpected }, observer: { _, _ in preconditionFailure("No AX observer") }))
        monitor.withState { $0.layoutChanged = true }
        let selection = ControllerNativeAppSnapshotSelection(.init(applicationWindow: .init(application: base, window: base, nativeWindow: window),
            windowRevision: revision, invalidationMonitor: monitor, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: source)
        let tree = ControllerRefetchableAppSnapshotTree(selection: selection, isAXTreeDiffingEnabled: true)
        let io = ControllerNativeRefetchIO(roleStatus: { _ in 0 }, fresh: { old in
            self.refreshes += 1; self.writesBeforeRefresh = !self.bridge.writes.isEmpty
            var fresh = old; fresh.value = "after"; return fresh
        }, capture: { _, _ in throw StringWriterFailure.unexpected })
        return .init(node: node, tree: tree, resources: resources, io: io)
    }
}

@MainActor enum NativeStringWriterChecks {
    static func run(output: URL) throws -> Int32 {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        for (value, text, expectedType) in [(NSNumber(value: 7), "1,234.5", CFNumberGetTypeID()),
            (kCFBooleanFalse! as AnyObject, "ON", CFBooleanGetTypeID()), ("old" as NSString, "Olá 👋", CFStringGetTypeID())] {
            let f = StringWriterFixture(); let h = try f.handle(value)
            try ControllerNativeStringValueWriter.set(text, on: h, resources: f.resources)
            check("typed payload \(text)", f.bridge.writes.count == 1 && f.bridge.writes[0].0 == "AXValue" && CFGetTypeID(f.bridge.writes[0].1.raw) == expectedType)
            check("successful write refreshes changed value \(text)", f.refreshes == 1 && f.writesBeforeRefresh && h.node.value == "after")
            check("encoded value uses captured snapshot \(text)", f.bridge.reads.isEmpty)
            if expectedType == CFNumberGetTypeID() {
                check("integer field accepts fractional numeric write", (f.bridge.writes[0].1.raw as? NSNumber)?.doubleValue == 1234.5)
            }
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle(nil)
            try ControllerNativeStringValueWriter.set("new", on: h, resources: f.resources)
            check("missing captured text value writes string without live fallback", (f.bridge.writes.first?.1.raw as? String) == "new" && f.bridge.reads.isEmpty)
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle(NSNumber(value: 3))
            var rejected = false
            do { try ControllerNativeStringValueWriter.set("bad", on: h, resources: f.resources) }
            catch ControllerStringConversionError.invalidNumber("bad") { rejected = true }
            check("conversion failure performs neither write nor refresh", rejected && f.bridge.writes.isEmpty && f.refreshes == 0 && h.node.value == "before")
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle("old" as NSString); f.bridge.failWrite = true
            var rejected = false
            do { try ControllerNativeStringValueWriter.set("new", on: h, resources: f.resources) }
            catch StringWriterFailure.write { rejected = true }
            check("provider failure propagates without raw fallback or refresh", rejected && f.bridge.writes.isEmpty && f.refreshes == 0 && h.node.value == "before")
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": checks, "hosted_provider_injected": true,
            "native_string_writer_and_refetch_adapter_executed": true, "actual_AX_write_focus_input_or_capture": false,
            "normal_native_request_routing_accepted": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native string writer: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}

@MainActor enum NativeFieldFocusBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        func backend(_ f: StringWriterFixture, _ h: ControllerNativeResolvedElement) -> ControllerNativeFieldFocus {
            let selection = h.containingTree.selection.value.applicationWindow
            return .init(resolved: h, captured: .init(application: ControllerNativeAppSnapshotContext.contextual(selection.application),
                window: ControllerNativeAppSnapshotContext.contextual(selection.window), focus: nil), resources: f.resources)
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle("old" as NSString, extra: ["AXFocused": kCFBooleanTrue!])
            try await ControllerFieldFocus(backend: backend(f, h)).focusFieldIfNeeded()
            check("captured focused state avoids live focus reads and writes", f.bridge.reads.isEmpty && f.bridge.writes.isEmpty && f.refreshes == 0)
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle("old" as NSString, extra: ["AXFocused": kCFBooleanFalse!])
            try await ControllerFieldFocus(backend: backend(f, h)).focusFieldIfNeeded()
            check("focus uses generic hosted CFBoolean write", f.bridge.writes.count == 1 && f.bridge.writes[0].0 == "AXFocused" && CFGetTypeID(f.bridge.writes[0].1.raw) == CFBooleanGetTypeID() && (f.bridge.writes[0].1.raw as? Bool) == true)
            check("post-write focus probe bypasses captured false value", f.bridge.reads == ["AXFocused"])
            check("focus write refreshes handle before live probe", f.refreshes == 1 && f.writesBeforeRefresh && h.node.value == "after")
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle("old" as NSString)
            try await ControllerFieldFocus(backend: backend(f, h)).focusFieldIfNeeded()
            check("unsupported focus attribute leaves native field untouched", f.bridge.reads.isEmpty && f.bridge.writes.isEmpty && f.refreshes == 0)
        }
        do {
            let f = StringWriterFixture(); let h = try f.handle("old" as NSString, extra: ["AXFocused": kCFBooleanFalse!]); f.bridge.failWrite = true
            var rejected = false
            do { try await ControllerFieldFocus(backend: backend(f, h)).focusFieldIfNeeded() }
            catch StringWriterFailure.write { rejected = true }
            check("failed native focus write propagates before refresh or live probe", rejected && f.bridge.reads.isEmpty && f.bridge.writes.isEmpty && f.refreshes == 0)
        }
        check("native focus adapter checks did not initialize AppKit", NSApp == nil)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": checks, "hosted_provider_injected": true,
            "native_focus_write_and_uncached_read_adapter_executed": true, "physical_input_focus_capture_or_actual_AX_write": false,
            "click_fallback_native_delivery_verified": false, "normal_native_request_routing_accepted": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native field focus: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
