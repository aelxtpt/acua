import ApplicationServices
import Foundation

@MainActor struct ControllerNativeSecondaryRuntime {
    let settle: @MainActor (ControllerNativeElementContext.Node, TimeInterval?) async throws -> ControllerNativeAppSnapshotCache?
    static func native(resources: ControllerNativeResources) -> Self {
        let runtime = ControllerNativeClickRuntime.native(resources: resources)
        return .init(settle: { try await runtime.settle($0, $1, 0.25, false) })
    }
}

@MainActor struct ControllerNativeSecondaryBackend: ControllerSecondaryActionBackend {
    typealias Element = ControllerNativeResolvedElement
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Menu = ControllerNativeElementContext.Node
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let runtime: ControllerNativeSecondaryRuntime
    private var menuBackend: ControllerNativeMenuInteraction { .init(owner: controller.owner, resources: controller.resources) }
    func prepare(_ id: Int) async throws -> (element: Element, tree: Tree) {
        let value = try await controller.prepareToInteract(id: id, timing: .finished, positionElement: true, animated: true)
        return (value.element, value.tree)
    }
    func descriptions(_ element: Element) -> [ControllerSecondaryActionDescription] {
        let resources = controller.resources
        let node = ControllerNativeAppSnapshotContext.contextual(element.node.element)
        let geometry = ControllerNativeGeometry.Backend(reader: resources.geometry)
        let fields = ControllerNativeSettleCapture.Fields(capture: .init(resources: resources))
        return ControllerSecondaryDescriptions(actions: {
            if let provider = resources.io.lookup(node.element) { return provider.actions() }
            var names: CFArray?
            let status = AXUIElementCopyActionNames(node.element.element, &names)
            guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
            return names as? [String] ?? []
        }, isDisclosable: { geometry.canDisclose(node) },
            isDisclosing: { (element.node.element.cachedAttribute("AXDisclosing") as? Bool) ?? false },
            predefined: EventStreamNodeAction.predefinedDescription,
            description: { try fields.actionDescription($0, of: element.node.element) },
            log: { resources.context.log("secondaryActionDescriptions", $0) }).read()
    }
    func openMenu(_ element: Element, tree: Tree) async throws -> Bool {
        try await ControllerMenuInteraction(backend: menuBackend).open(element, tree: tree)
    }
    private func clear(_ menu: Menu) -> Bool {
        let backend = menuBackend
        guard backend.isMenuBarItem(menu) else { return false }
        backend.clearFocusedMenuBarItem()
        backend.clearOpenedMenu()
        return true
    }
    func cancelMenu(_ element: Element) async -> Bool {
        clear(ControllerNativeAppSnapshotContext.contextual(element.node.element))
    }
    var cursorEnabled: Bool { ComputerUseFeaturePreferences.cursorEnabled }
    func pressCursor() async throws { try await controller.createVirtualCursorIfNeeded().press() }
    func perform(_ action: String, on element: Element) throws {
        try NativeElementAction.perform(ControllerNativeAppSnapshotContext.contextual(element.node.element), action: action,
            backend: ControllerNativeGeometry.Backend(reader: controller.resources.geometry))
    }
    var focusedMenuBarItem: Menu? { controller.owner.currentlyFocusedMenuBarItem }
    func clearMenu(_ menu: Menu) async { _ = clear(menu) }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle(delay: TimeInterval?) async throws -> Cache? { try await runtime.settle(controller.owner.app, delay) }
    func capture(cache: Cache?) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: false, skipScreenshot: false)
    }
}
extension ControllerNativeAppController {
    func performSecondaryAction(elementID: Int, action: String, returnAppSnapshot: Bool,
                                runtime: ControllerNativeSecondaryRuntime? = nil) async throws -> AppSnapshot? {
        try await ControllerSecondaryAction(backend: ControllerNativeSecondaryBackend(controller: self,
            runtime: runtime ?? .native(resources: resources))).perform(elementID: elementID, action: action, returnAppSnapshot: returnAppSnapshot)
    }
}
