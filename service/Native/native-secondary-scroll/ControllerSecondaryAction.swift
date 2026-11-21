import Foundation

struct ControllerSecondaryActionDescription: Sendable, Equatable {
    let name: String
    let description: String
}
enum ControllerSecondaryActionFailure: Error, Equatable {
    case invalidAction(String, elementID: Int)
}

@MainActor protocol ControllerSecondaryActionBackend {
    associatedtype Element: Sendable
    associatedtype Tree: Sendable
    associatedtype Menu: Sendable
    associatedtype Cache: Sendable
    associatedtype AppSnapshot: Sendable
    func prepare(_ id: Int) async throws -> (element: Element, tree: Tree)
    func descriptions(_ element: Element) -> [ControllerSecondaryActionDescription]
    func openMenu(_ element: Element, tree: Tree) async throws -> Bool
    func cancelMenu(_ element: Element) async -> Bool
    var cursorEnabled: Bool { get }
    func pressCursor() async throws
    func perform(_ action: String, on element: Element) throws
    var focusedMenuBarItem: Menu? { get }
    func clearMenu(_ menu: Menu) async
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle(delay: TimeInterval?) async throws -> Cache?
    func capture(cache: Cache?) async throws -> AppSnapshot
}

/// Select a published description, then handle menu state.
@MainActor struct ControllerSecondaryAction<Backend: ControllerSecondaryActionBackend> {
    let backend: Backend
    func perform(elementID: Int, action: String, returnAppSnapshot: Bool) async throws -> Backend.AppSnapshot? {
        let prepared = try await backend.prepare(elementID)
        guard let selected = backend.descriptions(prepared.element).first(where: { $0.description == action }) else {
            throw ControllerSecondaryActionFailure.invalidAction(action, elementID: elementID)
        }
        let handled: Bool
        if selected.name == "AXPick", try await backend.openMenu(prepared.element, tree: prepared.tree) {
            handled = true
        } else if selected.name == "AXCancel", await backend.cancelMenu(prepared.element) {
            handled = true
        } else {
            handled = false
            if backend.cursorEnabled { try await backend.pressCursor() }
            try backend.perform(selected.name, on: prepared.element)
            if let menu = backend.focusedMenuBarItem { await backend.clearMenu(menu) }
        }
        guard returnAppSnapshot else { backend.needsUISettleBeforeAppSnapshot = true; return nil }
        backend.needsUISettleBeforeAppSnapshot = false
        let cache = try await backend.settle(delay: handled ? 0.1 : nil)
        return try await backend.capture(cache: cache)
    }
}
