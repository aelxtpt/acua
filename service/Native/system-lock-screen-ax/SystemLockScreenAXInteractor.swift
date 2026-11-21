import Foundation
import CoreGraphics

struct LockScreenRevealClick: Equatable {
    let point: CGPoint
    let windowID: UInt32
    let windowBounds: CGRect
    // The caller explicitly supplies false: local Y is not inverted.
    let windowUsesFlippedCoordinates = false
}

@MainActor protocol LockScreenAXBackend {
    associatedtype Node
    associatedtype Batch
    func loginApplication() -> Node?
    func children(_ node: Node) -> [Node]
    func identifier(_ node: Node) -> String?
    func role(_ node: Node) -> String?
    func value(_ node: Node) -> String?
    func isEnabled(_ node: Node) -> Bool
    func frame(_ node: Node) -> CGRect?
    func window(_ node: Node) -> Node?
    func windowID(_ node: Node) throws -> UInt32
    func setEmptyValue(_ node: Node) throws
    func makeClick(_ click: LockScreenRevealClick) throws -> Batch
    func makeReturn() async throws -> Batch
    func send(_ batch: Batch) async throws
}

@MainActor struct SystemLockScreenAXInteractor<Backend: LockScreenAXBackend>: LockScreenAXInteracting {
    typealias Element = Backend.Node
    let backend: Backend

    func descendants(_ root: Element, maximumDepth: Int = 8) -> [Element] {
        guard maximumDepth >= 0 else { return [] }
        let direct = backend.children(root)
        var result = direct
        for child in direct { result += descendants(child, maximumDepth: maximumDepth - 1) }
        return result
    }
    func findPasswordField() -> Element? {
        guard let application = backend.loginApplication() else { return nil }
        return descendants(application).first { backend.identifier($0) == "UserPasswordTextField" }
    }
    func findPasswordEntryRevealCandidate() -> Element? {
        guard let application = backend.loginApplication() else { return nil }
        let nodes = descendants(application)
        guard let user = nodes.first(where: { backend.identifier($0) == "FocusedUser" }),
              let focusedFrame = backend.frame(user) else { return nil }
        let candidates = nodes.map { node in
            // Gather every candidate field before choosing, even for
            // entries whose role alone will later exclude them.
            LockScreenPasswordEntryCandidate(role: backend.role(node), identifier: backend.identifier(node),
                value: backend.value(node), isEnabled: backend.isEnabled(node), frame: backend.frame(node))
        }
        guard let index = LockScreenPasswordEntrySelection.index(in: candidates, focusedUserFrame: focusedFrame) else { return nil }
        return nodes[index]
    }
    func revealPasswordEntry(_ candidate: Element) async throws -> Bool {
        guard let frame = backend.frame(candidate), let window = backend.window(candidate),
              let bounds = backend.frame(window) else { return false }
        let id: UInt32
        do { id = try backend.windowID(window) } catch { return false }
        let batch: Backend.Batch
        do {
            batch = try backend.makeClick(.init(point: .init(x: frame.midX, y: frame.midY), windowID: id, windowBounds: bounds))
        } catch { return false }
        // Factory errors are swallowed; errors from the async sender propagate.
        try await backend.send(batch)
        return true
    }
    func clearPasswordField(_ field: Element) throws { try backend.setEmptyValue(field) }
    func submitReturn() async -> Bool {
        do { let batch = try await backend.makeReturn(); try await backend.send(batch); return true }
        catch { return false }
    }
}
