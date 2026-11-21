import CoreGraphics

enum ScrollEventFactory {
    // Events use pixel units and wheelCount 1 even with deltaX. On the
    // CoreGraphics path this drops horizontal deltas. Keep that behavior
    // rather than silently changing the wheel count.
    static func event(at point: CGPoint, deltaX: Int64, deltaY: Int64, windowID: UInt32?) throws -> CGEvent {
        guard let x = Int32(exactly: deltaX), let y = Int32(exactly: deltaY) else {
            throw ServiceError(.unhandledEvent, "Scroll distance exceeds the native event range")
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: y, wheel2: x, wheel3: 0) else {
            throw ServiceError(.unhandledEvent, "Could not create native scroll event")
        }
        event.location = point
        if let windowID {
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        }
        return event
    }
}
