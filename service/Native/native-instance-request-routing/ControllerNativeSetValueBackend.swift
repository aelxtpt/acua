import Foundation

@MainActor struct ControllerNativeSetValueRuntime {
    // Keyboard synthesis/targeting is mandatory until the common native
    // keyboard provider is composed. There is no legacy Actions fallback.
    let pressReturn: @MainActor (ControllerNativeElementContext.Node) async throws -> Void
    let settle: @MainActor (ControllerNativeElementContext.Node) async throws -> ControllerNativeAppSnapshotCache?
    static func native(resources: ControllerNativeResources,
                       pressReturn: @escaping @MainActor (ControllerNativeElementContext.Node) async throws -> Void) -> Self {
        let settling = ControllerNativeClickRuntime.native(resources: resources)
        return .init(pressReturn: pressReturn, settle: { application in
            try await settling.settle(application, nil, 0.25, false)
        })
    }
}

@MainActor struct ControllerNativeSetValueBackend: ControllerSetValueBackend {
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Element = ControllerNativeResolvedElement
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let runtime: ControllerNativeSetValueRuntime
    func prepare(_ id: Int) async throws -> ControllerClickPrepared<Tree, Element> {
        let value = try await controller.prepareToInteract(id: id, timing: nil, positionElement: true, animated: true)
        return .init(tree: value.tree, element: value.element)
    }
    private func contextual(_ element: Element) -> ControllerNativeElementContext.Node {
        ControllerNativeAppSnapshotContext.contextual(element.node.element)
    }
    func isValueSettable(_ element: Element) -> Bool {
        let node = contextual(element)
        return EventStreamAttributeAvailability.supports("AXValue", supported: node.snapshot.supported,
            requested: node.snapshot.requested, refresh: { controller.resources.context.context.environment.supported(node.element) }) &&
            controller.resources.io.isSettable("AXValue", on: node.element)
    }
    func focusFieldIfNeeded(_ element: Element, tree: Tree) async throws {
        let selection = tree.selection.value.applicationWindow
        let captured = ControllerNativeClickContext(application: ControllerNativeAppSnapshotContext.contextual(selection.application),
            window: ControllerNativeAppSnapshotContext.contextual(selection.window), focus: controller.owner.focusEnforcer)
        try await ControllerFieldFocus(backend: ControllerNativeFieldFocus(resolved: element, captured: captured, resources: controller.resources)).focusFieldIfNeeded()
    }
    func setStringValue(_ text: String, on element: Element) throws {
        try ControllerNativeStringValueWriter.set(text, on: element, resources: controller.resources)
    }
    func subrole(_ element: Element) -> String? { controller.resources.geometry.value("AXSubrole", on: contextual(element)) }
    func identifier(_ element: Element) -> String? { controller.resources.geometry.value("AXIdentifier", on: contextual(element)) }
    func keyShortcuts(_ element: Element) -> String? { controller.resources.geometry.value("AXKeyShortcutsValue", on: contextual(element)) }
    func ensureFocusEnforcer() { _ = controller.owner.activateFocusEnforcer() }
    var believesFocused: Bool? { controller.owner.focusEnforcer?.state.believesFocused }
    var lastTree: Tree? { controller.owner.lastAXTree }
    func captureForFocus() async throws -> Tree {
        _ = try await controller.updateAppSnapshot(treeCache: nil, disableAXDiffing: false, skipScreenshot: false)
        guard let tree = controller.owner.lastAXTree else { throw ControllerInteractionPreparationFailure.missingAppSnapshotTree }
        return tree
    }
    func enforceFocus(in tree: Tree) async throws {
        let window = ControllerNativeAppSnapshotContext.contextual(tree.selection.value.applicationWindow.window)
        try await controller.owner.focusEnforcer?.safelyEnforceActiveState(for: window)
    }
    func pressReturn() async throws { try await runtime.pressReturn(controller.owner.app) }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle() async throws -> Cache? { try await runtime.settle(controller.owner.app) }
    func capture(cache: Cache?) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: false, skipScreenshot: false)
    }
}

extension ControllerNativeAppController {
    func setValue(_ parameters: ControllerSetValueParameters, runtime: ControllerNativeSetValueRuntime) async throws -> AppSnapshot? {
        try await ControllerSetValueOperation(backend: ControllerNativeSetValueBackend(controller: self, runtime: runtime)).setValue(parameters)
    }
}
