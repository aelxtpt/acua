import Foundation
import CoreGraphics

/// wheelCount is ONE even though wheel2 receives deltaX.
struct ControllerScrollEventFactory<Source, Event> {
    let source: () -> Source?
    let create: (Source, Int32, UInt32, Int32, Int32, Int32) -> Event?
    let setLocation: (Event, CGPoint) -> Void
    let location: (Event) -> CGPoint
    let setInteger: (Event, UInt32, Int64) -> Void
    let optionalWindowField: () -> UInt32?
    let setWindowLocation: (Event, CGPoint) -> Void

    func make(at point: CGPoint, deltaX: Int, deltaY: Int, windowID: UInt32?,
              bounds: CGRect?, flipped: Bool) throws -> [Event] {
        guard let source = source() else { throw ControllerSynthesizedEventError.failedToCreateSource }
        // Integer narrowing is checked after acquiring the source.
        let y = Int32(deltaY), x = Int32(deltaX)
        guard let event = create(source, 0, 1, y, x, 0) else {
            throw ControllerKeyboardEventCreationError.failedToCreateCGEvent
        }
        setLocation(event, point)
        if let windowID {
            if let field = optionalWindowField() { setInteger(event, field, Int64(windowID)) }
            setInteger(event, 91, Int64(windowID))
            setInteger(event, 92, Int64(windowID))
            if let bounds {
                let actual = location(event)
                var local = actual.applying(.init(translationX: -bounds.minX, y: -bounds.minY))
                if flipped { local.y = bounds.height - local.y }
                setWindowLocation(event, local)
            }
        }
        return [event]
    }
}

@MainActor protocol ControllerScrollBackend {
    associatedtype Target: Sendable
    associatedtype Event: Sendable
    func point() -> CGPoint
    func target(at point: CGPoint) throws -> Target
    func events(at point: CGPoint, deltaX: Int, deltaY: Int, target: Target) throws -> [Event]
    func send(_ events: [Event], to target: Target, delay: Duration) async throws
}
@MainActor struct ControllerScroll<Backend: ControllerScrollBackend> {
    let backend: Backend
    func scroll(deltaX: Int, deltaY: Int) async throws {
        let target = try backend.target(at: backend.point())
        defer { withExtendedLifetime(target) {} }
        // Read controller geometry again after resolving the target.
        let events = try backend.events(at: backend.point(), deltaX: deltaX, deltaY: deltaY, target: target)
        try await backend.send(events, to: target, delay: .milliseconds(10))
    }
}
