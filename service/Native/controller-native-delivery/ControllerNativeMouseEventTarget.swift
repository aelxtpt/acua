import AppKit
import ApplicationServices
import Foundation

protocol ControllerNativeMouseHitTestBridge: ControllerNativeElementBridge {
    func element(at point: CGPoint) throws -> SettingsNativeAXElement?
}
enum ControllerNativeMouseHitTestFailure: Error { case unsupportedHostedHitTest }

/// Shared C92/C96 identity, snapshot and hosted-provider policies. No legacy
/// AXIndex or AXMenuSessions state participates in the native-controller path.
@MainActor struct ControllerNativeMouseEventTarget: ControllerMouseEventTargetBackend {
    typealias Node = ControllerNativeElementContext.Node
    let resources: ControllerNativeResources
    func ordinaryPID(_ application: Node) throws -> Int32 {
        try ControllerAXEnablementNative.pid(application.element, lookup: { resources.io.lookup($0)?.ordinaryPID })
    }
    func actualPID(_ node: Node) throws -> Int32 { try resources.context.identity.actualPID(node.element) }
    func windowID(_ node: Node) throws -> UInt32 { try resources.context.identity.windowID(node.element) }
    func optionalWindowID(_ node: Node) throws -> UInt32? {
        do { return try windowID(node) }
        catch ControllerWindowID.Failure.accessibility(let status) where status == AXError.illegalArgument.rawValue { return nil }
    }
    func children(_ node: Node) -> [Node] { resources.context.context.children(node) }
    func parent(_ node: Node) -> Node? { ControllerGlobalFocusNative.element("AXParent", node, context: resources.context) }
    func role(_ node: Node) -> String { resources.context.context.role(node) }
    func bundleIdentifier(_ application: Node) -> String? { resources.context.context.environment.bundleIdentifier(application.element) }
    func frame(_ window: Node) -> CGRect? { resources.geometry.frame(window) }
    func processKind(_ pid: Int32) -> ControllerMouseProcessKind {
        guard let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching else { return .unavailable }
        return app.activationPolicy == .prohibited ? .service : .application
    }
    func missingContainingProcess() {
        resources.context.log("log[24579732a7739189470a]", ControllerMouseTargetFailure.unresolvedContext(reason: 0))
    }
    func frontWindowID(at point: CGPoint) -> UInt32? {
        // Test the supplied point against each AppKit screen frame, then flip
        // using that screen's HEIGHT. This keeps multi-display behavior
        // correct instead of applying a primary-screen origin.
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        let position = CGPoint(x: point.x, y: screen.frame.height - point.y)
        let number = NSWindow.windowNumber(at: position, belowWindowWithWindowNumber: 0)
        return ControllerWindowDescription.lookup(UInt32(number))?.id
    }
    func systemElement(at point: CGPoint) throws -> Node? {
        let root = SettingsNativeAXElement(element: AXUIElementCreateSystemWide())
        if let provider = resources.io.lookup(root) {
            guard let provider = provider as? any ControllerNativeMouseHitTestBridge else {
                throw ControllerNativeMouseHitTestFailure.unsupportedHostedHitTest
            }
            return try provider.element(at: point).map(resources.context.context.node)
        }
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(root.element, Float(point.x), Float(point.y), &hit)
        guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
        return hit.map { resources.context.context.node(.init(element: $0)) }
    }
    func windowBounds(_ id: UInt32) -> CGRect? { ControllerWindowDescription.lookup(id)?.bounds }
}
