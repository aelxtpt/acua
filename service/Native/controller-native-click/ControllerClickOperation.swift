import Foundation

enum ControllerClickButton: Sendable { case left, right }
struct ControllerClickParameters: Sendable {
    let elementID: Int
    var button: ControllerClickButton? = nil
    var count: Int? = nil
    var hold: Duration? = nil
    var key: String? = nil
    var returnAppSnapshot = true
    var animateCursor = true
}
struct ControllerClickPrepared<Tree: Sendable, Element: Sendable>: Sendable { let tree: Tree; let element: Element }
struct ControllerClickDelivery: Sendable {
    let button: ControllerClickButton
    let count: Int
    let hold: Duration?
    let key: ControllerHeldClickKey
    let alwaysSimulate: Bool
}
@MainActor protocol ControllerClickBackend {
    associatedtype Tree: Sendable
    associatedtype Element: Sendable
    associatedtype Cursor: Sendable
    associatedtype Menu: Sendable
    associatedtype Cache: Sendable
    associatedtype AppSnapshot: Sendable
    func prepare(_ id: Int, timing: CursorInteractionTiming, position: Bool, animated: Bool) async throws -> ControllerClickPrepared<Tree, Element>
    var cursorEnabled: Bool { get }
    func ensureCursor() -> Cursor
    func openMenu(_ element: Element, tree: Tree) async throws -> Bool
    func cursorVisible(_ cursor: Cursor) -> Bool
    var alwaysSimulateClick: Bool { get }
    func click(_ element: Element, tree: Tree, delivery: ControllerClickDelivery, cursor: Cursor?) async throws
    var focusedMenuBarItem: Menu? { get }
    func clearMenuIfMenuBarItem(_ menu: Menu) async
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle(delay: Double?, notificationDelay: Double, includingScrollEvents: Bool) async throws -> Cache?
    func capture(cache: Cache?, disableAXDiffing: Bool, skipScreenshot: Bool) async throws -> AppSnapshot
}
@MainActor struct ControllerClickOperation<Backend: ControllerClickBackend> {
    let backend: Backend
    func click(_ parameters: ControllerClickParameters) async throws -> Backend.AppSnapshot? {
        // Parse the entire key string before preparing the element.
        let key = try parameters.key.map(ControllerHeldClickKey.parse) ?? .none
        let prepared = try await backend.prepare(parameters.elementID, timing: .closeEnough, position: true, animated: parameters.animateCursor)
        let cursor = backend.cursorEnabled ? backend.ensureCursor() : nil
        let eligibleMenu = (parameters.button ?? .left) == .left && (parameters.count == nil || parameters.count == 1)
            && parameters.hold == nil && key.keyCode == nil && key.eventFlags == 0
        if eligibleMenu, try await backend.openMenu(prepared.element, tree: prepared.tree) {
            return try await finish(returnAppSnapshot: parameters.returnAppSnapshot, delay: 0.1)
        }
        // Visibility is read only after a failed/skipped menu path. The
        // animate option gates the cursor passed to the lower-level click.
        let visible = cursor.map(backend.cursorVisible) ?? false
        let force = backend.alwaysSimulateClick
        let delivery = ControllerClickDelivery(button: parameters.button ?? .left, count: parameters.count ?? 1,
            hold: parameters.hold, key: key, alwaysSimulate: force)
        try await backend.click(prepared.element, tree: prepared.tree, delivery: delivery,
            cursor: parameters.animateCursor && visible ? cursor : nil)
        if let tracked = backend.focusedMenuBarItem { await backend.clearMenuIfMenuBarItem(tracked) }
        return try await finish(returnAppSnapshot: parameters.returnAppSnapshot, delay: nil)
    }
    private func finish(returnAppSnapshot: Bool, delay: Double?) async throws -> Backend.AppSnapshot? {
        guard returnAppSnapshot else { backend.needsUISettleBeforeAppSnapshot = true; return nil }
        backend.needsUISettleBeforeAppSnapshot = false
        let cache = try await backend.settle(delay: delay, notificationDelay: 0.25, includingScrollEvents: false)
        return try await backend.capture(cache: cache, disableAXDiffing: false, skipScreenshot: false)
    }
}
