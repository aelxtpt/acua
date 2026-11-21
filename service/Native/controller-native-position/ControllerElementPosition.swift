import Foundation

@MainActor protocol ControllerElementPositionBackend {
    associatedtype Element: Sendable
    associatedtype Tree: Sendable
    associatedtype Cursor: Sendable
    associatedtype Timing
    func clickablePoint(_ element: Element) async throws -> ControllerPointResult
    var cursorEnabled: Bool { get }
    func ensureCursor() -> Cursor
    func windowID(_ tree: Tree) -> UInt32
    func delegateMove(_ cursor: Cursor, point: CGPoint, windowID: UInt32, animated: Bool) async
    func move(_ cursor: Cursor, point: CGPoint, windowID: UInt32, timing: Timing, animated: Bool) async -> Bool
    func notifyMoved(_ cursor: Cursor)
}
@MainActor struct ControllerElementPosition<Backend: ControllerElementPositionBackend> {
    let backend: Backend
    func position(_ element: Backend.Element, timing: Backend.Timing?, tree: Backend.Tree, animated: Bool) async throws -> Bool {
        let result = try await backend.clickablePoint(element)
        guard let point = result.point, let timing, backend.cursorEnabled else { return result.scrolled }
        let cursor = backend.ensureCursor()
        // Read the selection's current window after cursor creation.
        let window = backend.windowID(tree)
        await backend.delegateMove(cursor, point: point, windowID: window, animated: animated)
        _ = await backend.move(cursor, point: point, windowID: window, timing: timing, animated: animated)
        backend.notifyMoved(cursor)
        // Interrupted movement does not change the scroll result.
        return result.scrolled
    }
}
