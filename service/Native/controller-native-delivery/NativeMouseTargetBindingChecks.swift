import AppKit
import ApplicationServices
import Foundation

private enum MouseBridgeTestFailure: Error { case hit }
private final class MouseBridgeRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    private var queried: [CGPoint] = []
    func set(_ key: SettingsNativeAXElement, _ row: [String: ControllerNativeAXValue]) { lock.withLock { stored[key] = row } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { stored[key] ?? [:] } }
    func hit(_ point: CGPoint) { lock.withLock { queried.append(point) } }
    var points: [CGPoint] { lock.withLock { queried } }
}
private class MouseBaseBridge: ControllerNativeElementBridge, @unchecked Sendable {
    let rows: MouseBridgeRows, key: SettingsNativeAXElement
    init(_ rows: MouseBridgeRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
    var ordinaryPID: Int32 { -42 }; var actualPID: Int32 { 0 }; var windowID: UInt32 { 0 }; var bundleIdentifier: String? { nil }
    func supported() -> Set<String> { Set(rows.values(key).keys) }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { rows.values(key).filter { attributes.contains($0.key) } }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { rows.values(key)[attribute] }
    func perform(_ action: String) throws { preconditionFailure("No action") }
    func actions() -> [String] { [] }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { false }
    func setBoolean(_ attribute: String, _ value: Bool) throws { preconditionFailure("No AX write") }
}
private final class MouseHitBridge: MouseBaseBridge, ControllerNativeMouseHitTestBridge, @unchecked Sendable {
    let result: SettingsNativeAXElement?
    let throwsHit: Bool
    init(_ rows: MouseBridgeRows, _ key: SettingsNativeAXElement, result: SettingsNativeAXElement?, throwsHit: Bool = false) {
        self.result = result; self.throwsHit = throwsHit; super.init(rows, key)
    }
    func element(at point: CGPoint) throws -> SettingsNativeAXElement? {
        rows.hit(point); if throwsHit { throw MouseBridgeTestFailure.hit }; return result
    }
}

@MainActor enum NativeMouseTargetBindingChecks {
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let rows = MouseBridgeRows()
        let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(72001))
        let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(72002))
        let child = SettingsNativeAXElement(element: AXUIElementCreateApplication(72003))
        var position = CGPoint(x: -200, y: 100), size = CGSize(width: 80, height: 0)
        let rawPoint = AXValueCreate(.cgPoint, &position)!, rawSize = AXValueCreate(.cgSize, &size)!
        rows.set(app, ["AXRole": .init(raw: "AXApplication" as NSString)])
        rows.set(window, ["AXRole": .init(raw: "AXWindow" as NSString), "AXChildren": .init(raw: [child.element] as NSArray),
            "AXPosition": .init(raw: rawPoint), "AXSize": .init(raw: rawSize)])
        rows.set(child, ["AXRole": .init(raw: "AXButton" as NSString), "AXParent": .init(raw: window.element)])
        // The real composition binds both identity and I/O lookups. Supplying
        // only I/O would deliberately leave identity getters on their raw path.
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in
            .init(actualPID: 0, windowID: 0, bundleIdentifier: nil)
        }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No input") })
        let actions = ControllerFocusSynthesizedActionState()
        let resources = ControllerNativeResources(context: context, lookup: { MouseHitBridge(rows, $0, result: child) }, windowServer: ws, actions: actions)
        let adapter = ControllerNativeMouseEventTarget(resources: resources)
        let a = resources.context.context.node(app), w = resources.context.context.node(window), c = resources.context.context.node(child)
        check("native target reads ordinary cached PID independently of actual PID", try adapter.ordinaryPID(a) == -42 && adapter.actualPID(a) == 0)
        check("native target retains authoritative cached zero window identity", try adapter.windowID(w) == 0 && adapter.optionalWindowID(w) == 0)
        check("native target children use same shared context and snapshot", adapter.children(w).map(\.element) == [child])
        check("native target parent uses hosted AXParent through shared reader", adapter.parent(c)?.element == window)
        check("native target role uses captured snapshot", adapter.role(w) == "AXWindow" && adapter.role(c) == "AXButton")
        check("native target preserves nil bundle from present hosted provider", adapter.bundleIdentifier(a) == nil)
        check("native target general frame decodes position-size fallback without validity guard", adapter.frame(w) == CGRect(origin: position, size: size))
        let point = CGPoint(x: 1.123456789, y: -300.987654321)
        let hit = try adapter.systemElement(at: point)
        check("native system hit uses optional hosted provider without raw AX fallback", hit?.element == child && rows.points == [point])
        check("native system-hit wrapper uses shared context for captured role", hit.map(adapter.role) == "AXButton")
        let absent = ControllerNativeResources(context: context, lookup: { MouseHitBridge(rows, $0, result: nil) }, windowServer: ws)
        check("native hosted nil hit remains nil", try ControllerNativeMouseEventTarget(resources: absent).systemElement(at: point) == nil)
        let failing = ControllerNativeResources(context: context, lookup: { MouseHitBridge(rows, $0, result: child, throwsHit: true) }, windowServer: ws)
        var propagated = false
        do { _ = try ControllerNativeMouseEventTarget(resources: failing).systemElement(at: point) } catch MouseBridgeTestFailure.hit { propagated = true }
        check("native hosted hit failure propagates without raw fallback", propagated)
        let incapable = ControllerNativeResources(context: context, lookup: { MouseBaseBridge(rows, $0) }, windowServer: ws)
        var rejected = false
        do { _ = try ControllerNativeMouseEventTarget(resources: incapable).systemElement(at: point) } catch ControllerNativeMouseHitTestFailure.unsupportedHostedHitTest { rejected = true }
        check("present hosted provider lacking hit capability fails explicitly", rejected)
        check("native missing process classification remains unavailable", adapter.processKind(-999999) == .unavailable)
        check("binding construction starts no input delivery or owner focus assertion", resources.actions.value.1 == 0 && resources.actions === actions)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "actual_AX_query_write_focus_input_cursor_window_screen_capture_or_preferences": false,
            "native_data_adapters_executed": true, "hosted_effect_providers_injected": true]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native mouse target bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
