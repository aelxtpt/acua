import Foundation

@MainActor struct ControllerNativeMenuInteraction: ControllerMenuInteractionBackend {
    typealias Element = ControllerNativeResolvedElement
    typealias Menu = ControllerNativeElementContext.Node
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Focus = ControllerFocusNativeBindings.Focus
    typealias Window = ControllerNativeElementContext.Node
    let owner: ControllerNativeAppSnapshotBackend.Owner
    let resources: ControllerNativeResources
    func childMenu(_ element: Element) -> Menu? {
        let node = ControllerNativeAppSnapshotContext.contextual(element.node.element)
        let context = resources.context.context
        guard context.role(node) == "AXMenuBarItem" else { return nil }
        return context.children(node).first { context.role($0) == "AXMenu" }
    }
    func ensureFocus() -> Focus { owner.activateFocusEnforcer() }
    func window(_ tree: Tree) -> Window { tree.selection.source.window }
    func enforce(_ focus: Focus, window: Window) async throws { try await focus.safelyEnforceActiveState(for: window) }
    func setFocusedMenuBarItem(_ element: Element) {
        owner.currentlyFocusedMenuBarItem = resources.context.context.node(.init(element: element.node.element.element))
    }
    func setOpenedMenu(_ menu: Menu) { owner.currentlyOpenedMenu = menu }
    func isMenuBarItem(_ menu: Menu) -> Bool { resources.context.context.role(menu) == "AXMenuBarItem" }
    func clearFocusedMenuBarItem() { owner.currentlyFocusedMenuBarItem = nil }
    func clearOpenedMenu() { owner.currentlyOpenedMenu = nil }
}
