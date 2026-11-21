import AppKit
import ApplicationServices
import Foundation

private class PointReadBridge: ControllerNativeElementBridge, @unchecked Sendable {
    var ordinaryPID: Int32 { -123 }; var actualPID: Int32 { 0 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    private let lock = NSLock()
    var values: [String: ControllerNativeAXValue] = [:]
    private var events: [String] = []
    func record(_ value: String) { lock.withLock { events.append(value) } }
    var trace: [String] { lock.withLock { events } }
    func supported() -> Set<String> { record("supported"); return Set(values.keys) }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { record("batch"); return values.filter { attributes.contains($0.key) } }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { record("read:" + attribute); return values[attribute] }
    func perform(_ action: String) throws { record("action:" + action) }
    func actions() -> [String] { ["AXScrollToVisible"] }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { true }
    func setBoolean(_ attribute: String, _ value: Bool) throws { record("bool:" + attribute) }
}
private final class PointValueBridge: PointReadBridge, ControllerNativeElementValueBridge, @unchecked Sendable {
    private(set) var last: (String, ControllerNativeAXValue)?
    func setValue(_ value: ControllerNativeAXValue, for attribute: String) throws { last = (attribute, value); record("value:" + attribute) }
}
private final class PointLeafSink: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: [String] = []
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    var values: [String] { lock.withLock { recorded } }
}
@MainActor enum NativePointBindingChecks {
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        let key = SettingsNativeAXElement(element: AXUIElementCreateSystemWide()), bridge = PointValueBridge()
        func rect(_ value: CGRect) -> ControllerNativeAXValue { var value = value; return .init(raw: AXValueCreate(.cgRect, &value)!) }
        func node(_ values: [String: ControllerNativeAXValue], supported: Set<String>? = nil, requested: Set<String>? = nil) -> ControllerNativeElementContext.Node {
            .init(element: key, snapshot: .init(supported: supported ?? Set(values.keys), values: values, requested: requested))
        }
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 0, windowID: 51, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No input") })
        let resources = ControllerNativeResources(context: context, lookup: { _ in bridge }, windowServer: ws)
        let backend = ControllerNativeClickablePoint(geometry: resources.geometry)
        let old = CGRect(x: 1, y: 2, width: 30, height: 40), fresh = CGRect(x: 50, y: 60, width: 70, height: 80)
        bridge.values = ["AXFrame": rect(fresh), "AXRole": .init(raw: "AXWindow" as NSString), "AXEnabled": .init(raw: NSNumber(value: false)), "AXValue": .init(raw: NSNumber(value: 0.9))]
        let captured = node(["AXFrame": rect(old), "AXRole": .init(raw: "AXButton" as NSString)])
        check("native point role reads captured role rather than provider", backend.role(captured) == "AXButton" && bridge.trace.isEmpty)
        check("native cached AXFrame avoids hosted read", backend.frameAttribute(captured, uncached: false) == old && bridge.trace.isEmpty)
        check("native post-reveal AXFrame bypasses captured frame", backend.frameAttribute(captured, uncached: true) == fresh && bridge.trace.last == "read:AXFrame")
        let masked = node([:], supported: [], requested: ["AXFrame", "AXValue", "AXParent"])
        let count = bridge.trace.count
        check("cached frame availability mask prevents raw fallback", backend.frameAttribute(masked, uncached: false) == nil && bridge.trace.count == count)
        check("uncached frame preserves known-unsupported attribute decision", backend.frameAttribute(masked, uncached: true) == nil)
        check("uncached unrequested frame is read from provider", backend.frameAttribute(node([:], supported: [], requested: []), uncached: true) == fresh)
        let cachedDisabled = node(["AXEnabled": .init(raw: NSNumber(value: false))])
        check("native cached disabled scrollbar is excluded", backend.enabled(cachedDisabled) == false)
        let notCaptured = node([:], supported: ["AXEnabled"]); let beforeEnabled = bridge.trace.count
        check("uncaptured enabled flag remains unknown without provider read", backend.enabled(notCaptured) == nil && bridge.trace.count == beforeEnabled)
        check("native scrollbar value ignores stale captured value", backend.scrollValue(node(["AXValue": .init(raw: NSNumber(value: 0.1))])) == 0.9)
        let beforeValue = bridge.trace.count
        check("masked native scrollbar value is not queried", backend.scrollValue(masked) == nil && bridge.trace.count == beforeValue)
        try backend.setScrollValue(0.8, captured)
        check("native numeric write uses hosted value capability", bridge.last?.0 == "AXValue" && (bridge.last?.1.raw as? NSNumber)?.doubleValue == 0.8)
        try backend.setVisibleRect(old, captured)
        let raw = bridge.last!.1
        let decodedRect = try ControllerNativeGeometryDecoding.decode(raw, as: CGRect.self, strict: true)
        check("native rectangle write keeps actual AXValue encoding", bridge.last?.0 == "AXMakeScreenRectVisible" && decodedRect == old)
        try backend.setReveal(captured)
        check("native cell reveal uses hosted Boolean writer", bridge.trace.last == "bool:AXScrollToVisible")
        try backend.performReveal(captured)
        check("native action reveal uses hosted action writer", bridge.trace.last == "action:AXScrollToVisible")
        let readOnly = PointReadBridge()
        let other = ControllerNativeResources(context: context, lookup: { _ in readOnly }, windowServer: ws)
        let limited = ControllerNativeClickablePoint(geometry: other.geometry)
        var rejected = false
        do { try limited.setScrollValue(0.2, captured) } catch ControllerNativePointWriteFailure.unsupportedHostedValueWrite { rejected = true }
        check("present hosted provider without numeric writer never falls through to raw AX", rejected && readOnly.trace.isEmpty)
        let parent = AXUIElementCreateApplication(70001)
        bridge.values["AXParent"] = .init(raw: parent)
        let absentParent = node([:], supported: [], requested: ["AXParent"])
        let beforeParent = bridge.trace.count
        check("cached parent respects absent requested attribute", backend.parent(absentParent, uncached: false) == nil && bridge.trace.count == beforeParent)
        check("native uncached parent preserves known-unsupported decision", backend.parent(absentParent, uncached: true) == nil)
        check("native unrequested parent is rewrapped through shared context", backend.parent(node([:], supported: [], requested: []), uncached: true)?.element == .init(element: parent))
        // Use actual AXValue payloads for the frame getter's initial fallback.
        var p = CGPoint(x: 3, y: 4), z = CGSize(width: 5, height: 6)
        let fallback = node(["AXPosition": .init(raw: AXValueCreate(.cgPoint, &p)!), "AXSize": .init(raw: AXValueCreate(.cgSize, &z)!)], supported: ["AXPosition", "AXSize"], requested: ["AXFrame", "AXPosition", "AXSize"])
        check("initial frame getter permits position-size fallback", backend.frame(fallback) == CGRect(origin: p, size: z))
        check("final frame attribute does not use position-size fallback", backend.frameAttribute(fallback, uncached: false) == nil)
        var bound = backend; let sink = PointLeafSink()
        let updated = node(["AXRole": .init(raw: "AXGroup" as NSString), "AXFrame": rect(fresh)])
        bound.leafKey = key; bound.currentLeaf = { updated }
        bound.setLeafReveal = { sink.record("Boolean") }
        bound.setLeafValue = { _, attribute in sink.record(attribute) }
        check("native leaf reads follow the refetched handle's current snapshot", bound.role(captured) == "AXGroup" && bound.frameAttribute(captured, uncached: false) == fresh)
        let priorWrites = bridge.trace.count
        try bound.setReveal(captured)
        check("native leaf Boolean write goes through refetch hook", sink.values == ["Boolean"] && bridge.trace.count == priorWrites)
        try bound.setVisibleRect(old, captured)
        check("native leaf rectangle write goes through general refetch hook", sink.values == ["Boolean", "AXMakeScreenRectVisible"] && bridge.trace.count == priorWrites)
        try bound.setScrollValue(0.4, captured)
        check("native scrollbar value write bypasses leaf refresh hook", sink.values.count == 2 && bridge.last?.0 == "AXValue" && (bridge.last?.1.raw as? NSNumber)?.doubleValue == 0.4)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "native_snapshot_geometry_IO_and_value_writers_executed": true, "AX_provider_injected": true,
            "actual_AX_query_write_window_input_cursor_or_screen_capture": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native point bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
