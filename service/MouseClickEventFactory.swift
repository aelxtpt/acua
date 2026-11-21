import CoreGraphics
import Foundation

enum MouseClickEventFactory {
    // Movement has no held modifiers or click state, but consumes
    // the same event-number sequence used by subsequent click pairs.
    static func movement(at point: CGPoint, windowID: UInt32, eventNumber: Int64) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw ServiceError(.unhandledEvent, "Could not create mouse event")
        }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 0)
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        return event
    }
    // Distinguish left/right from all other UInt32
    // buttons, then writes the raw button field through CoreGraphics.
    static func events(at point: CGPoint, button: UInt32, clickCount: Int64,
                       flags: CGEventFlags, windowID: UInt32, eventNumber: Int64) throws -> (down: CGEvent, up: CGEvent) {
        let base: CGMouseButton = button == 0 ? .left : (button == 1 ? .right : .center)
        let down: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let up: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        let source = CGEventSource(stateID: .hidSystemState)
        func make(_ type: CGEventType) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: base) else {
                throw ServiceError(.unhandledEvent, "Could not create mouse event")
            }
            event.flags = flags
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
            event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
            event.setIntegerValueField(.mouseEventSubtype, value: 3)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            return event
        }
        return (try make(down), try make(up))
    }

    static func dragEvents(from start: CGPoint, to end: CGPoint, button: UInt32, clickCount: Int64,
                           flags: CGEventFlags, windowID: UInt32, eventNumber: Int64,
                           nextMotionEventNumber: (() -> Int64)? = nil) throws -> (down: CGEvent, motion: [CGEvent], up: CGEvent) {
        let base: CGMouseButton = button == 0 ? .left : (button == 1 ? .right : .center)
        let down: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let dragged: CGEventType = button == 0 ? .leftMouseDragged : (button == 1 ? .rightMouseDragged : .otherMouseDragged)
        let up: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        let source = CGEventSource(stateID: .hidSystemState)
        func make(_ type: CGEventType, at point: CGPoint, number: Int64, motion: Bool = false) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: base) else {
                throw ServiceError(.unhandledEvent, "Could not create mouse event")
            }
            event.flags = flags
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.setIntegerValueField(.mouseEventClickState, value: motion ? 0 : clickCount)
            event.setIntegerValueField(.mouseEventNumber, value: number)
            event.setIntegerValueField(.mouseEventSubtype, value: 3)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            return event
        }
        let midpoint = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        return try SynthesizedMouseGesture.drag(pressNumber: eventNumber,
            nextMotionNumber: nextMotionEventNumber ?? { eventNumber + 1 },
            press: { try make(down, at: start, number: $0) },
            motion: { number in try [start, midpoint, end].map { try make(dragged, at: $0, number: number, motion: true) } },
            release: { try make(up, at: end, number: $0) })
    }
}
