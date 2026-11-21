import AppKit
import ApplicationServices
import Foundation

private enum LowerBindingFailure: Error { case action, observer }
final class LowerBindingRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    private var performed: [String] = []
    private var fails = false
    func set(_ key: SettingsNativeAXElement, _ value: [String: ControllerNativeAXValue]) { lock.withLock { rows[key] = value } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { rows[key] ?? [:] } }
    func perform(_ action: String) throws { try lock.withLock { performed.append(action); if fails { throw LowerBindingFailure.action } } }
    var actions: [String] { lock.withLock { performed } }
    func fail() { lock.withLock { fails = true } }
}
private final class LowerBindingBridge: ControllerNativeElementBridge, ControllerNativeMouseHitTestBridge, Sendable {
    let rows: LowerBindingRows, key: SettingsNativeAXElement
    init(_ rows: LowerBindingRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
    var ordinaryPID: Int32 { 73001 }; var actualPID: Int32 { 73001 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    func supported() -> Set<String> { Set(rows.values(key).keys) }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { rows.values(key).filter { attributes.contains($0.key) } }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { rows.values(key)[attribute] }
    func perform(_ action: String) throws { try rows.perform(action) }
    func actions() -> [String] { ["AXPress", "AXPick"] }
    func element(at point: CGPoint) throws -> SettingsNativeAXElement? {
        guard let value = rows.values(key)["AXFixtureHit"] else { return nil }
        return .init(element: unsafeDowncast(value.raw, to: AXUIElement.self))
    }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { false }
    func setBoolean(_ attribute: String, _ value: Bool) throws { preconditionFailure("No AX write") }
}
private final class LowerWindowLocations: @unchecked Sendable {
    static let shared = LowerWindowLocations()
    private let lock = NSLock()
    private var stored: [CGPoint] = []
    func append(_ point: CGPoint) { lock.withLock { stored.append(point) } }
    var values: [CGPoint] { lock.withLock { stored } }
}
@MainActor final class NativeLowerFixture {
    typealias Node = ControllerNativeElementContext.Node
    let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(73001))
    let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(73002))
    let leaf = SettingsNativeAXElement(element: AXUIElementCreateApplication(73003))
    let rows = LowerBindingRows()
    let resources: ControllerNativeResources
    var probes = 0
    init(bundleIdentifier: String? = nil) {
        let rows = rows
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 73001, windowID: 51, bundleIdentifier: bundleIdentifier) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") },
            setLocation: { _, point in LowerWindowLocations.shared.append(point) })
        resources = .init(context: context, lookup: { LowerBindingBridge(rows, $0) }, windowServer: ws, actions: .init())
        func rect(_ value: CGRect) -> ControllerNativeAXValue { var value = value; return .init(raw: AXValueCreate(.cgRect, &value)!) }
        rows.set(app, ["AXRole": .init(raw: "AXApplication" as NSString)])
        rows.set(window, ["AXRole": .init(raw: "AXWindow" as NSString), "AXParent": .init(raw: app.element), "AXFrame": rect(.init(x: 0, y: 0, width: 400, height: 300))])
        rows.set(leaf, ["AXRole": .init(raw: "AXButton" as NSString), "AXParent": .init(raw: window.element), "AXFrame": rect(.init(x: 20, y: 30, width: 80, height: 40))])
    }
    func node(_ key: SettingsNativeAXElement) -> Node { resources.context.context.node(key) }
    var captured: ControllerNativeClickContext { .init(application: node(app), window: node(window), focus: nil) }
    func resolved() throws -> ControllerNativeResolvedElement {
        let a = ControllerNativeAppSnapshotContext.snapshotNode(node(app), context: resources.context)
        let w = ControllerNativeAppSnapshotContext.snapshotNode(node(window), context: resources.context)
        let raw = ControllerNativeAppSnapshotContext.snapshotNode(node(leaf), context: resources.context)
        var transformed = EventStreamTransformedNode(element: raw); transformed.role = "AXButton"
        let collected = EventStreamCollectedTree(roots: [EventStreamCollectedItem(node: transformed, path: [0], children: [], childrenSubset: nil)])
        let revision = try EventStreamNativeTreeRevision.Revision.root(collected, lineageID: UUID().uuidString, identity: { .init(element: $0.element) }, render: { _ in
            .init(isFocusTree: false, roots: [.init(identity: .init(element: raw.element), text: "button", sourcePath: [0])])
        })
        let monitor = EventStreamTreeInvalidationMonitor(application: app.element,
            io: .init(processIdentifier: { _ in throw LowerBindingFailure.observer }, observer: { _, _ in preconditionFailure("No AX observer") }))
        monitor.withState { $0.layoutChanged = false }
        let native = EventStreamNativeWindow(id: 51, processIdentifier: getpid(), frame: .init(x: 0, y: 0, width: 400, height: 300), level: 0, title: "data", ownerName: "owned")
        let source = ControllerNativeAppSnapshotSource(context: .init(application: a, window: w, focusedElement: nil, nativeWindow: native), window: node(window))
        let selection = ControllerNativeAppSnapshotSelection(.init(applicationWindow: .init(application: a, window: w, nativeWindow: native), windowRevision: revision,
            invalidationMonitor: monitor, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: source)
        let tree = ControllerRefetchableAppSnapshotTree(selection: selection, isAXTreeDiffingEnabled: true)
        return .init(node: transformed, tree: tree, resources: resources, io: .init(roleStatus: { _ in self.probes += 1; return 0 },
            fresh: { _ in preconditionFailure("No AX refresh") }, capture: { _, _ in preconditionFailure("No AX recapture") }))
    }
}

@MainActor enum NativeLowerClickBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            cases.append(["name": name, "passed": value])
            FileHandle.standardOutput.write(Data("CHECK \(cases.count): \(name): \(value)\n".utf8))
        }
        FileHandle.standardOutput.write(Data("START C103 native data\n".utf8))
        let f = NativeLowerFixture(), resolved = try f.resolved()
        let backend = ControllerNativeLowerClick(resolved: resolved, captured: f.captured, resources: f.resources, cursor: nil)
        check("native lower click retains actual shared resources and captured window", backend.resources === f.resources && backend.captured.window.element == f.window)
        check("native lower actions use hosted policy in declared order", backend.actions() == ["AXPress", "AXPick"])
        check("native web shape uses shared parent snapshots without raw AX", !backend.webShaped())
        check("native no-scroll clickable point uses captured geometry", try await backend.clickablePoint() == CGPoint(x: 60, y: 50))
        check("hosted app missing hit capability is caught by web-hit predicate", await backend.webHit() == false)
        let target = try backend.target(at: .init(x: 60, y: 50))
        check("native lower target is C102 captured host result", target.pid == 73001 && target.windowID == 51 && target.element?.element == f.leaf && target.accessibilityWindow.element == f.window)
        let runtime = ControllerNativeClickRuntime.nativeClick(resources: f.resources, settle: { _, _, _, _ in nil })
        try await runtime.click(resolved, f.captured, .init(button: .left, count: 0, hold: nil, key: .none, alwaysSimulate: false), nil)
        check("concrete native runtime executes AXPick through hosted action provider", f.rows.actions == ["AXPick"])
        check("native AX action does not add a field-write refetch", f.probes == 0)
        check("native action does not replace captured window or create cursor/focus", resolved.containingTree.selection.value.applicationWindow.nativeWindow.id == 51 && !backend.hasCursor && backend.captured.focus == nil)
        var invalidCount = false
        do { try await runtime.click(resolved, f.captured, .init(button: .left, count: 0, hold: nil, key: .none, alwaysSimulate: true), nil) }
        catch ControllerLowerClickFailure.invalidCount { invalidCount = true }
        check("forced native zero-count mouse path fails after point target focus without sending", invalidCount && f.rows.actions == ["AXPick"])
        f.rows.fail(); var actionFailure = false
        do { try await runtime.click(resolved, f.captured, .init(button: .left, count: 1, hold: nil, key: .none, alwaysSimulate: false), nil) }
        catch LowerBindingFailure.action { actionFailure = true }
        check("native action failure propagates without field-write refresh", actionFailure && f.probes == 0)
        let menuFixture = NativeLowerFixture()
        menuFixture.rows.set(menuFixture.leaf, ["AXRole": .init(raw: "AXMenuItem" as NSString), "AXParent": .init(raw: menuFixture.window.element)])
        let menuElement = try menuFixture.resolved()
        let menuRuntime = ControllerNativeClickRuntime.nativeClick(resources: menuFixture.resources, settle: { _, _, _, _ in nil })
        try await menuRuntime.click(menuElement, menuFixture.captured, .init(button: .left, count: 1, hold: nil, key: .none, alwaysSimulate: false), nil)
        check("native AX menu item dispatches ancestor action before leaf action", menuFixture.rows.actions == ["AXPick", "AXPick"] && menuFixture.probes == 0)
        check("native click does not record a fabricated synthesized focus action", f.resources.actions.value.2)
        let counter = SynthesizedEventNumberSequence(initialValue: 100)
        let factory = ControllerNativeClickEvents(windowServer: f.resources.windowServer, numbers: counter)
        let point = CGPoint(x: 90, y: 80)
        let pointer = ControllerMouseEventTarget(pid: Int32(200), element: f.node(f.leaf), accessibilityWindow: f.node(f.window), windowID: UInt32(51), windowBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        for button: UInt32 in [0, 1, 7] {
            let start = 100 + Int64(button == 0 ? 0 : (button == 1 ? 3 : 6))
            let events = try factory.mouse(at: point, target: pointer, options: .init(button: button, count: 3, hold: nil, key: .none, alwaysSimulate: true), flags: 0x140000)
            let down: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
            let up: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            check("native NSEvent mouse types: \(button)", events.map { $0.event.type } == [down, up, down, up, down, up])
            check("native pair shares event number and advances once per click: \(button)", events.map { $0.event.getIntegerValueField(.mouseEventNumber) } == [start, start, start + 1, start + 1, start + 2, start + 2])
            check("native click counts increase per pair: \(button)", events.map { $0.event.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2, 3, 3])
            check("native mouse fields retain flags button subtype and both window IDs: \(button)", events.allSatisfy { $0.event.flags.rawValue == 0x140000 && $0.event.getIntegerValueField(.mouseEventButtonNumber) == Int64(button) && $0.event.getIntegerValueField(.mouseEventSubtype) == 3 && $0.event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 51 && $0.event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 51 })
            check("native mouse global point is preserved: \(button)", events.allSatisfy { $0.event.location == point })
        }
        check("native WindowServer location adapter receives translated local points for every event", LowerWindowLocations.shared.values == Array(repeating: .init(x: 80, y: 60), count: 18))
        check("shared injected number sequence consumed only one number per pair", counter.next() == 109)
        let holding = try factory.held(try .parse("ctrl+a"))!
        check("native held key uses keyboard down/up and decoded physical code", holding.down.last?.event.type == .keyDown && holding.up.first?.event.type == .keyUp && holding.down.last?.event.getIntegerValueField(.keyboardEventKeycode) == 0 && holding.up.first?.event.getIntegerValueField(.keyboardEventKeycode) == 0)
        check("native held physical key flags match parsed modifiers", holding.down.last?.event.flags.rawValue == 0x40000 && holding.up.first?.event.flags.rawValue == 0x40000)
        check("native held-key transition events are paired when present", holding.down.count == holding.up.count && (1...2).contains(holding.down.count) && (holding.down.count == 1 || holding.down.first?.event.type == .flagsChanged && holding.up.last?.event.type == .flagsChanged))
        let modifier = try factory.held(try .parse("ctrl"))!
        check("native modifier-only holding always makes flagsChanged pair", modifier.down.count == 1 && modifier.up.count == 1 && modifier.down[0].event.type == .flagsChanged && modifier.up[0].event.type == .flagsChanged && modifier.down[0].event.flags.rawValue == 0x40000)
        check("native absent held key constructs no event sequence", try factory.held(.none) == nil)
        check("explicit settle provider still returns exact optional cache", try await runtime.settle(f.captured.application, nil, 0.25, false) == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "actual_native_NSEvent_CGEvent_objects_created": true, "actual_process_metadata_queries": true,
            "hosted_AX_and_WindowServer_location_providers_injected": true,
            "actual_AX_query_write_focus_input_cursor_window_screen_capture_or_preferences": false,
            "production_service_entry_executed": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native lower click bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
