import ApplicationServices
import Foundation

enum ControllerNativeScrollEvents {
    typealias Event = ControllerFocusNativeEvent
    static func factory(windowServer: ControllerNativeWindowServer) -> ControllerScrollEventFactory<CGEventSource, Event> {
        .init(source: { CGEventSource(stateID: .hidSystemState) },
            create: { source, units, count, y, x, z in
                CGEvent(scrollWheelEvent2Source: source, units: CGScrollEventUnit(rawValue: UInt32(units))!,
                    wheelCount: count, wheel1: y, wheel2: x, wheel3: z).map { .init(event: $0) }
            }, setLocation: { $0.event.location = $1 }, location: { $0.event.location },
            setInteger: { event, field, value in
                if let field = CGEventField(rawValue: field) { event.event.setIntegerValueField(field, value: value) }
            }, optionalWindowField: { 51 }, setWindowLocation: { windowServer.setLocation($0.event, $1) })
    }
}

@MainActor final class ControllerNativeScrollTarget {
    let value: ControllerMouseEventTarget<ControllerNativeElementContext.Node>
    init(_ value: ControllerMouseEventTarget<ControllerNativeElementContext.Node>) { self.value = value }
}
@MainActor struct ControllerNativeScrollRuntime {
    let events: @MainActor (CGPoint, Int, Int, ControllerNativeScrollTarget) throws -> [ControllerFocusNativeEvent]
    let send: @Sendable ([ControllerFocusNativeEvent], Int32, Duration?) async throws -> Void
    static func native(resources: ControllerNativeResources) -> Self {
        .init(events: { point, x, y, target in
            let target = target.value
            return try ControllerNativeScrollEvents.factory(windowServer: resources.windowServer).make(at: point,
                deltaX: x, deltaY: y, windowID: target.windowID, bounds: target.windowBounds,
                flipped: target.windowUsesFlippedCoordinates)
        }, send: { try await ControllerNativeKeyboardEvents.send($0, to: $1, delay: $2) })
    }
}
@MainActor struct ControllerNativeScrollBackend: ControllerScrollBackend {
    typealias Target = ControllerNativeScrollTarget
    typealias Event = ControllerFocusNativeEvent
    let controller: ControllerNativeAppController
    let runtime: ControllerNativeScrollRuntime
    func point() -> CGPoint {
        let point = controller.owner.cursorPositionInScaledCoordinates
        let scale = controller.owner.scalingFactor
        let origin = controller.owner.visibleRect.origin
        return point.applying(.init(scaleX: scale, y: scale)).applying(.init(translationX: origin.x, y: origin.y))
    }
    func target(at point: CGPoint) throws -> Target {
        let windows = controller.orderedWindows()
        return .init(try ControllerCoordinateTargeting(backend: ControllerNativeCoordinateTarget(resources: controller.resources))
            .target(at: point, application: controller.owner.app, windows: windows))
    }
    func events(at point: CGPoint, deltaX: Int, deltaY: Int, target: Target) throws -> [Event] {
        try runtime.events(point, deltaX, deltaY, target)
    }
    func send(_ events: [Event], to target: Target, delay: Duration) async throws {
        try await runtime.send(events, target.value.pid, delay)
    }
}
extension ControllerNativeAppController {
    func scroll(deltaX: Int, deltaY: Int, runtime: ControllerNativeScrollRuntime? = nil) async throws {
        try await ControllerScroll(backend: ControllerNativeScrollBackend(controller: self,
            runtime: runtime ?? .native(resources: resources))).scroll(deltaX: deltaX, deltaY: deltaY)
    }
}
