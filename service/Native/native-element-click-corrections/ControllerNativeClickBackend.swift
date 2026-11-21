import Foundation

@MainActor struct ControllerNativeClickContext {
    let application: ControllerNativeElementContext.Node
    let window: ControllerNativeElementContext.Node
    let focus: ControllerFocusNativeBindings.Focus?
}
/// Native click delivery and native UI settling are mandatory runtime
/// capabilities. There is no no-op provider or legacy AXIndex substitution.
@MainActor struct ControllerNativeClickRuntime {
    let click: @MainActor (ControllerNativeResolvedElement, ControllerNativeClickContext, ControllerClickDelivery, ControllerApprovedCursor?) async throws -> Void
    let settle: @MainActor (ControllerNativeElementContext.Node, Double?, Double, Bool) async throws -> ControllerNativeAppSnapshotCache?
}
@MainActor struct ControllerNativeClickBackend: ControllerClickBackend {
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Element = ControllerNativeResolvedElement
    typealias Cursor = ControllerApprovedCursor
    typealias Menu = ControllerNativeElementContext.Node
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let runtime: ControllerNativeClickRuntime
    var cursorCreationEnvironment: ControllerNativeCursorCreationEnvironment? = nil
    private var menus: ControllerMenuInteraction<ControllerNativeMenuInteraction> {
        .init(backend: .init(owner: controller.owner, resources: controller.resources))
    }
    func prepare(_ id: Int, timing: CursorInteractionTiming, position: Bool, animated: Bool) async throws -> ControllerClickPrepared<Tree, Element> {
        let value = try await controller.prepareToInteract(id: id, timing: timing, positionElement: position, animated: animated)
        return .init(tree: value.tree, element: value.element)
    }
    var cursorEnabled: Bool { ComputerUseFeaturePreferences.cursorEnabled }
    func ensureCursor() -> Cursor {
        controller.createVirtualCursorIfNeeded(environment: cursorCreationEnvironment)
    }
    func openMenu(_ element: Element, tree: Tree) async throws -> Bool { try await menus.open(element, tree: tree) }
    func cursorVisible(_ cursor: Cursor) -> Bool { cursor.visibleWindowID != nil }
    var alwaysSimulateClick: Bool { ComputerUseFeaturePreferences.alwaysSimulateClick }
    func click(_ element: Element, tree: Tree, delivery: ControllerClickDelivery, cursor: Cursor?) async throws {
        let selection = tree.selection.value.applicationWindow
        let captured = ControllerNativeClickContext(application: ControllerNativeAppSnapshotContext.contextual(selection.application),
            window: ControllerNativeAppSnapshotContext.contextual(selection.window), focus: controller.owner.focusEnforcer)
        try await runtime.click(element, captured, delivery, cursor)
    }
    var focusedMenuBarItem: Menu? { controller.owner.currentlyFocusedMenuBarItem }
    func clearMenuIfMenuBarItem(_ menu: Menu) async { menus.clearIfMenuBarItem(menu) }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle(delay: Double?, notificationDelay: Double, includingScrollEvents: Bool) async throws -> Cache? {
        try await runtime.settle(controller.owner.app, delay, notificationDelay, includingScrollEvents)
    }
    func capture(cache: Cache?, disableAXDiffing: Bool, skipScreenshot: Bool) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: disableAXDiffing, skipScreenshot: skipScreenshot)
    }
}
extension ControllerNativeAppController {
    func click(_ parameters: ControllerClickParameters, runtime: ControllerNativeClickRuntime) async throws -> AppSnapshot? {
        try await ControllerClickOperation(backend: ControllerNativeClickBackend(controller: self, runtime: runtime)).click(parameters)
    }
}
