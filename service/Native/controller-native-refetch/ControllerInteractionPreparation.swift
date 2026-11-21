import Foundation

enum ControllerInteractionPreparationFailure: Error, Equatable { case missingAppSnapshotTree }

@MainActor protocol ControllerInteractionPreparationBackend {
    associatedtype Tree: Sendable
    associatedtype Element: Sendable
    associatedtype Timing
    var lastTree: Tree? { get }
    func resolve(_ id: Int, in tree: Tree) throws -> Element
    func ensureFocusEnforcer()
    func position(_ element: Element, timing: Timing?, tree: Tree, animated: Bool) async throws -> Bool
    func actualPID(_ element: Element) throws -> Int32
    func requireAllowed(_ pid: Int32) throws
}

@MainActor struct ControllerInteractionPreparation<Backend: ControllerInteractionPreparationBackend> {
    struct Result: Sendable { let tree: Backend.Tree; let element: Backend.Element }
    let backend: Backend
    /// Retain the initially selected tree across positioning.
    /// A successful scroll repeats the first ID lookup on that same tree.
    func prepare(id: Int, timing: Backend.Timing?, positionElement: Bool, animated: Bool) async throws -> Result {
        guard let tree = backend.lastTree else { throw ControllerInteractionPreparationFailure.missingAppSnapshotTree }
        var element = try backend.resolve(id, in: tree)
        backend.ensureFocusEnforcer()
        if positionElement {
            if try await backend.position(element, timing: timing, tree: tree, animated: animated) {
                element = try backend.resolve(id, in: tree)
            }
        }
        let pid = try backend.actualPID(element)
        try backend.requireAllowed(pid)
        return .init(tree: tree, element: element)
    }
}
