import Foundation

@MainActor protocol ControllerMenuInteractionBackend {
    associatedtype Element: Sendable
    associatedtype Menu: Sendable
    associatedtype Tree: Sendable
    associatedtype Focus: Sendable
    associatedtype Window: Sendable
    func childMenu(_ element: Element) -> Menu?
    func ensureFocus() -> Focus
    func window(_ tree: Tree) -> Window
    func enforce(_ focus: Focus, window: Window) async throws
    func setFocusedMenuBarItem(_ element: Element)
    func setOpenedMenu(_ menu: Menu)
    func isMenuBarItem(_ menu: Menu) -> Bool
    func clearFocusedMenuBarItem()
    func clearOpenedMenu()
}
@MainActor struct ControllerMenuInteraction<Backend: ControllerMenuInteractionBackend> {
    let backend: Backend
    func open(_ element: Backend.Element, tree: Backend.Tree) async throws -> Bool {
        guard let menu = backend.childMenu(element) else { return false }
        let focus = backend.ensureFocus()
        let window = backend.window(tree)
        try await backend.enforce(focus, window: window)
        backend.setFocusedMenuBarItem(element)
        backend.setOpenedMenu(menu)
        return true
    }
    func clearIfMenuBarItem(_ menu: Backend.Menu) {
        guard backend.isMenuBarItem(menu) else { return }
        backend.clearFocusedMenuBarItem()
        backend.clearOpenedMenu()
    }
}
