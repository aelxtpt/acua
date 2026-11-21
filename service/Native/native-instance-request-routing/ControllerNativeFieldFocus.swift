import ApplicationServices
import Foundation

@MainActor struct ControllerNativeFieldFocus: ControllerFieldFocusBackend {
    let resolved: ControllerNativeResolvedElement
    let captured: ControllerNativeClickContext
    let resources: ControllerNativeResources
    private var element: ControllerNativeElementContext.Node { ControllerNativeAppSnapshotContext.contextual(resolved.node.element) }
    func role() -> String { resources.context.context.role(element) }
    func supports(_ attribute: String) -> Bool {
        let node = element
        return EventStreamAttributeAvailability.supports(attribute, supported: node.snapshot.supported,
            requested: node.snapshot.requested, refresh: { resources.context.context.environment.supported(node.element) })
    }
    func isFocusable() -> Bool {
        guard supports("AXFocused") else { return false }
        // Read the role before querying native settable status. The
        // field-special branch and generic branch both reach the raw AX IO.
        _ = role()
        return resources.io.isSettable("AXFocused", on: element.element)
    }
    func capturedFocused() -> Bool {
        guard let raw = resolved.node.element.cachedAttribute("AXFocused") else { return false }
        return (try? ControllerNativeGeometryDecoding.decode(.init(raw: raw), as: Bool.self, strict: false)) ?? false
    }
    func bundleIdentifier() -> String? { resources.context.context.environment.bundleIdentifier(element.element) }
    func supportsDOMClassList() -> Bool { supports("AXDOMClassList") }
    func setFocused() throws {
        try resolved.afterWriting { node in
            try ControllerNativeClickablePoint(geometry: resources.geometry).write(.init(raw: kCFBooleanTrue!),
                attribute: "AXFocused", node: ControllerNativeAppSnapshotContext.contextual(node.element), refreshLeaf: false)
        }
    }
    func uncachedFocused() -> Bool? {
        let node = element
        guard EventStreamAttributeAvailability.mayRead("AXFocused", supported: node.snapshot.supported, requested: node.snapshot.requested) else { return nil }
        do {
            guard let raw = try resources.context.context.environment.read(node.element, "AXFocused") else { return nil }
            return try ControllerNativeGeometryDecoding.decode(raw, as: Bool.self, strict: true)
        } catch { resources.context.log("AXFocused", error); return nil }
    }
    func clickForFocus() async throws {
        // The field helper uses no virtual cursor and never forces simulation.
        let backend = ControllerNativeLowerClick(resolved: resolved, captured: captured, resources: resources, cursor: nil)
        try await ControllerLowerClick(backend: backend).click(.init(button: 0, count: 1, hold: nil, key: .none, alwaysSimulate: false))
    }
}
