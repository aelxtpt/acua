import Foundation
import CoreGraphics

@MainActor protocol ControllerPageScrollBackend {
    associatedtype Element
    associatedtype AppSnapshot
    func move(to position: ControllerScaledCursorPosition) async throws
    var visibleSize: CGSize { get }
    var visibleOrigin: CGPoint { get }
    var scalingFactor: Double { get }
    func prepare(_ id: Int) async throws -> Element
    func frame(_ element: Element) -> CGRect?
    func clickablePoint(_ element: Element) async throws -> CGPoint?
    func scroll(deltaX: Int, deltaY: Int) async throws
    func capture() async throws -> AppSnapshot
    func markNeedsSettle()
}

/// No explicit UI settling or clearing on the capture branch.
@MainActor struct ControllerPageScroll<Backend: ControllerPageScrollBackend> {
    let backend: Backend
    func perform(at target: XPCAppUsageBody.Target, direction: XPCAppUsageBody.ComputerUseIPCScrollDirection,
                 pages: Double, returnAppSnapshot: Bool) async throws -> Backend.AppSnapshot? {
        guard pages > 0 else { throw ControllerActionDispatchFailure.invalidScrollPages }
        let size: CGSize
        switch target {
        case .coordinate(let point):
            try await backend.move(to: .init(x: Int64(point.x), y: Int64(point.y)))
            size = backend.visibleSize
        case .elementID(let raw):
            guard let id = Int(raw) else { throw ControllerActionDispatchFailure.invalidElementID }
            let element = try await backend.prepare(id)
            //Capture dimensions before the awaited clickable-point lookup.
            size = backend.frame(element)?.size ?? backend.visibleSize
            if let point = try await backend.clickablePoint(element) {
                let candidate = backend.scalingFactor
                let scale = candidate > 0 ? candidate : 1
                let origin = backend.visibleOrigin
                try await backend.move(to: .init(x: Int64((point.x-origin.x)/scale),
                    y: Int64((point.y-origin.y)/scale)))
            }
        }
        let nativeDirection = NativeScroll.Direction(direction.rawValue)!
        let delta = try NativeScroll.delta(direction: nativeDirection, pages: pages, size: size)
        try await backend.scroll(deltaX: Int(delta.x), deltaY: Int(delta.y))
        if returnAppSnapshot { return try await backend.capture() }
        backend.markNeedsSettle()
        return nil
    }
}
