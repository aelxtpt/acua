import Foundation
import CoreGraphics

enum ControllerCoordinateTargetFailure: Error, Equatable {
    case noWindows
    case noWindowAtPoint(CGPoint)
}

@MainActor protocol ControllerCoordinateTargetBackend {
    associatedtype Node
    associatedtype Target
    func frame(_ window: Node) -> CGRect?
    func element(at point: CGPoint, application: Node) throws -> Node?
    func target(at point: CGPoint, application: Node, window: Node, element: Node?) throws -> Target
}

/// Input order determines the first containing AX window.
@MainActor struct ControllerCoordinateTargeting<Backend: ControllerCoordinateTargetBackend> {
    let backend: Backend
    func target(at point: CGPoint, application: Backend.Node, windows: [Backend.Node]) throws -> Backend.Target {
        guard !windows.isEmpty else { throw ControllerCoordinateTargetFailure.noWindows }
        guard let window = windows.first(where: { backend.frame($0)?.contains(point) == true }) else {
            throw ControllerCoordinateTargetFailure.noWindowAtPoint(point)
        }
        let element = try backend.element(at: point, application: application)
        return try backend.target(at: point, application: application, window: window, element: element)
    }
}

enum ControllerOrderedWindows {
    /// Snapshot the registry before querying CGWindowListCreate(0x11, 0).
    static func select<Node>(registered: [UInt32: Node], orderedIDs: [UInt32]) -> [Node] {
        orderedIDs.compactMap { registered[$0] }
    }
}
