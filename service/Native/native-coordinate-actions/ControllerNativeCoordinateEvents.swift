import AppKit
import ApplicationServices

/// NSEvents are constructed before their CGEvents are extracted.
/// Constructors and window-local coordinate setter are separable from posting.
@MainActor struct ControllerNativeCoordinateEvents {
    var numbers: SynthesizedEventNumberSequence = SynthesizedEventNumbers.shared
    let setWindowLocation: (CGEvent, CGPoint) -> Void
    var construct: (NSEvent.EventType, CGPoint, Int, Int64, Int) -> CGEvent? = { type, point, window, number, count in
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window, context: nil, eventNumber: Int(number), clickCount: count, pressure: 1)?.cgEvent
    }
    private func make(_ type: NSEvent.EventType, point: CGPoint, button: UInt32, count: Int,
                      number: Int64, flags: UInt64, windowID: UInt32?, bounds: CGRect?, flipped: Bool) throws -> CGEvent {
        guard let event = construct(type, point, Int(windowID ?? 0), number, count) else {
            throw ControllerLowerClickFailure.cannotCreateEvent
        }
        event.flags = .init(rawValue: flags)
        event.location = point
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        if let windowID {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            if let bounds {
                var local = CGPoint(x: event.location.x - bounds.minX, y: event.location.y - bounds.minY)
                if flipped { local.y = bounds.height - local.y }
                setWindowLocation(event, local)
            }
        }
        return event
    }
    func movement(at point: CGPoint, windowID: UInt32?, bounds: CGRect?, flipped: Bool = false) throws -> [CGEvent] {
        // The NSEvent movement constructor uses clickCount=1.
        [try make(.mouseMoved, point: point, button: 0, count: 1, number: numbers.next(),
                  flags: 0, windowID: windowID, bounds: bounds, flipped: flipped)]
    }
    func click(at start: CGPoint, destination: CGPoint?, button: UInt32, count: Int, flags: UInt64,
               windowID: UInt32?, bounds: CGRect?, flipped: Bool = false) throws -> [CGEvent] {
        guard count > 0 else { throw ControllerLowerClickFailure.invalidCount }
        let down: NSEvent.EventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let up: NSEvent.EventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        let dragged: NSEvent.EventType = button == 0 ? .leftMouseDragged : (button == 1 ? .rightMouseDragged : .otherMouseDragged)
        var events: [CGEvent] = []
        for index in 1...count {
            let number = numbers.next()
            func event(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int64, _ clickCount: Int) throws -> CGEvent {
                try make(type, point: point, button: button, count: clickCount, number: number,
                         flags: flags, windowID: windowID, bounds: bounds, flipped: flipped)
            }
            events.append(try event(down, start, number, index))
            if let destination {
                let motion = numbers.next()
                let midpoint = CGPoint(x: (start.x + destination.x) * 0.5, y: (start.y + destination.y) * 0.5)
                for point in [start, midpoint, destination] { events.append(try event(dragged, point, motion, 0)) }
            }
            events.append(try event(up, destination ?? start, number, index))
        }
        return events
    }
}
