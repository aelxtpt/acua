import AppKit
import ApplicationServices
import Foundation

/// Optional hosted providers can supply non-Boolean values as well. A present
/// provider without this capability reports failure; it never falls through
/// to a raw write on a different object.
protocol ControllerNativeElementValueBridge: ControllerNativeElementBridge {
    func setValue(_ value: ControllerNativeAXValue, for attribute: String) throws
}
enum ControllerNativePointWriteFailure: Error { case unsupportedHostedValueWrite }

struct ControllerNativeClickablePoint: ControllerClickablePointBackend {
    typealias Node = ControllerNativeElementContext.Node
    typealias Identity = SettingsNativeAXElement
    let geometry: ControllerNativeGeometry
    var leafKey: Identity? = nil
    var currentLeaf: (@Sendable () -> Node)? = nil
    var setLeafReveal: (@Sendable () throws -> Void)? = nil
    var setLeafValue: (@Sendable (ControllerNativeAXValue, String) throws -> Void)? = nil
    private var context: ControllerNativeElementContext { geometry.context }
    private func current(_ node: Node) -> Node { node.element == leafKey ? currentLeaf?() ?? node : node }
    func identity(_ node: Node) -> Identity { current(node).element }
    func role(_ node: Node) -> String { context.context.role(current(node)) }
    func title(_ node: Node) -> String? { geometry.value("AXTitle", on: current(node)) }
    func bundle(_ node: Node) -> String? { context.context.environment.bundleIdentifier(current(node).element) }
    func frame(_ node: Node) -> CGRect? { geometry.frame(current(node)) }
    func frameAttribute(_ node: Node, uncached: Bool) -> CGRect? {
        let node = current(node)
        if !uncached { return geometry.value("AXFrame", on: node) }
        guard EventStreamAttributeAvailability.mayRead("AXFrame", supported: node.snapshot.supported, requested: node.snapshot.requested) else { return nil }
        do {
            guard let value = try context.context.environment.read(node.element, "AXFrame") else { return nil }
            return try ControllerNativeGeometryDecoding.decode(value, as: CGRect.self, strict: true)
        } catch { context.log("AXFrame", error); return nil }
    }
    func parent(_ node: Node, uncached: Bool) -> Node? {
        let node = current(node)
        if !uncached { return ControllerGlobalFocusNative.element("AXParent", node, context: context) }
        guard EventStreamAttributeAvailability.mayRead("AXParent", supported: node.snapshot.supported, requested: node.snapshot.requested) else { return nil }
        do {
            guard let value = try context.context.environment.read(node.element, "AXParent"),
                  let key = try ControllerNativeElementDecoding.element(value, strict: true) else { return nil }
            return context.context.node(key)
        } catch { context.log("AXParent", error); return nil }
    }
    func children(_ node: Node) -> [Node] { context.context.children(current(node)) }
    func actions(_ node: Node) -> [String] { geometry.io.actions(current(node).element) }
    func supportedAndSettable(_ attribute: String, _ node: Node) -> Bool {
        let node = current(node)
        return EventStreamAttributeAvailability.supports(attribute, supported: node.snapshot.supported, requested: node.snapshot.requested,
            refresh: { context.context.environment.supported(node.element) }) && settable(attribute, node)
    }
    func settable(_ attribute: String, _ node: Node) -> Bool { geometry.io.isSettable(attribute, on: current(node).element) }
    func performReveal(_ node: Node) throws { try geometry.io.perform("AXScrollToVisible", on: current(node).element, context: context) }
    func setReveal(_ node: Node) throws {
        if node.element == leafKey, let setLeafReveal { try setLeafReveal(); return }
        try geometry.io.setBoolean("AXScrollToVisible", true, on: current(node).element, context: context)
    }
    func setVisibleRect(_ rect: CGRect, _ node: Node) throws {
        var rect = rect
        guard let raw = AXValueCreate(.cgRect, &rect) else { throw ControllerNativeElementDecoding.Failure.typeMismatch }
        try write(.init(raw: raw), attribute: "AXMakeScreenRectVisible", node: node)
    }
    func scrollBar(_ node: Node, vertical: Bool) -> Node? { ControllerGlobalFocusNative.element(vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar", current(node), context: context) }
    func enabled(_ node: Node) -> Bool? {
        guard let value = current(node).snapshot.values["AXEnabled"] else { return nil }
        return try? ControllerNativeGeometryDecoding.decode(value, as: Bool.self, strict: false)
    }
    func scrollValue(_ node: Node) -> CGFloat? {
        let node = current(node)
        guard EventStreamAttributeAvailability.mayRead("AXValue", supported: node.snapshot.supported, requested: node.snapshot.requested) else { return nil }
        do {
            guard let raw = try context.context.environment.read(node.element, "AXValue"), let number = raw.raw as? NSNumber else { return nil }
            return CGFloat(truncating: number)
        } catch { context.log("AXValue", error); return nil }
    }
    func setScrollValue(_ value: CGFloat, _ node: Node) throws { try write(.init(raw: NSNumber(value: Double(value))), attribute: "AXValue", node: node, refreshLeaf: false) }
    func write(_ value: ControllerNativeAXValue, attribute: String, node: Node, refreshLeaf: Bool = true) throws {
        if refreshLeaf, node.element == leafKey, let setLeafValue { try setLeafValue(value, attribute); return }
        let key = current(node).element
        if let bridge = geometry.io.lookup(key) {
            guard let writer = bridge as? any ControllerNativeElementValueBridge else { throw ControllerNativePointWriteFailure.unsupportedHostedValueWrite }
            try writer.setValue(value, for: attribute); return
        }
        let work: @Sendable () throws -> Void = {
            let status = AXUIElementSetAttributeValue(key.element, attribute as CFString, value.raw)
            guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
        }
        if (try? context.identity.actualPID(key)) == getpid() && !Thread.isMainThread { try DispatchQueue.main.sync(execute: work) }
        else { try work() }
    }
    func application(_ bundle: String) -> Node? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first.map { context.context.node(.init(element: AXUIElementCreateApplication($0.processIdentifier))) }
    }
    func hitTest(_ application: Node, _ point: CGPoint) -> Node? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application.element.element, Float(point.x), Float(point.y), &element) == .success, let element else { return nil }
        return context.context.node(.init(element: element))
    }
    func same(_ left: Node, _ right: Node) -> Bool { CFEqual(current(left).element.element, current(right).element.element) }
    func now() -> TimeInterval { Date.timeIntervalSinceReferenceDate }
    func delay(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
