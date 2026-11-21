import Foundation

enum ControllerKeyboardProcessKind: Sendable { case unavailable, application, service }
struct ControllerKeyboardTarget<Node: Sendable>: Sendable {
    let pid: Int32
    // Retains the focused node itself, including when its containing
    // service supplies a different PID. It does not retain just the ancestor.
    let focusedElement: Node?
}
@MainActor protocol ControllerKeyboardTargetBackend {
    associatedtype Node: Sendable
    func ordinaryPID(_ application: Node) throws -> Int32
    func focusedElement(_ application: Node) -> Node?
    func parent(_ element: Node) -> Node?
    func actualPID(_ element: Node) throws -> Int32
    func processKind(_ pid: Int32) -> ControllerKeyboardProcessKind
    func missingContainingProcess()
}
@MainActor struct ControllerKeyboardTargeting<Backend: ControllerKeyboardTargetBackend> {
    let backend: Backend
    func target(_ application: Backend.Node) throws -> ControllerKeyboardTarget<Backend.Node> {
        let host = try backend.ordinaryPID(application)
        guard let focused = backend.focusedElement(application) else { return .init(pid: host, focusedElement: nil) }
        for ancestor in AXParentChain(start: focused, parent: backend.parent) {
            guard let pid = try? backend.actualPID(ancestor) else { continue }
            switch backend.processKind(pid) {
            case .unavailable: continue
            case .application: return .init(pid: host, focusedElement: focused)
            case .service: return .init(pid: pid == host ? host : pid, focusedElement: focused)
            }
        }
        backend.missingContainingProcess()
        return .init(pid: host, focusedElement: focused)
    }
}
