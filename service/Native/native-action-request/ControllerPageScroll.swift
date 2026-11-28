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
    /// The center of the element's visible part, when its own center is hidden.
    func visiblePartCenter(_ element: Element) async throws -> CGPoint?
}
extension ControllerPageScrollBackend {
    func visiblePartCenter(_ element: Element) async throws -> CGPoint? { nil }
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
            let frame = backend.frame(element)
            size = frame?.size ?? backend.visibleSize
            // A scroll goes to whatever is under the pointer. An element whose
            // center is hidden is scrolled at the center of its visible part.
            // With a frame and nothing of it visible, the scroll would land
            // elsewhere; without a frame, the pointer stays where it was.
            var target = try await backend.clickablePoint(element)
            if target == nil { target = try await backend.visiblePartCenter(element) }
            if target == nil, frame != nil {
                throw ServiceError(.unknownError, ClickableGeometry.offscreenScrollMessage)
            }
            if let point = target {
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
