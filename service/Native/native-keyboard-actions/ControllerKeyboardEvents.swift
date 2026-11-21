import Foundation

struct ControllerKeyboardStroke: Sendable, Equatable {
    let keyCode: UInt16
    let flags: UInt64
    let unicode: [UInt16]?
}
enum ControllerSynthesizedEventError: Error, Equatable { case failedToCreateSource, failedToTranslateKeyCodes }
enum ControllerKeyboardEventCreationError: Error, Equatable { case failedToCreateCGEvent }

/// One source per sequence, with per-stroke modifier sampling.
/// All events are constructed before sending; construction failure posts none.
struct ControllerKeyboardEventFactory<Source, Event> {
    let source: () -> Source?
    let currentFlags: () -> UInt64
    let flagsEvent: (Source, UInt64) -> Event?
    let keyboardEvent: (Source, UInt16, Bool, UInt64, [UInt16]?) -> Event?
    func make(_ strokes: [ControllerKeyboardStroke]) throws -> [Event] {
        guard let source = source() else { throw ControllerSynthesizedEventError.failedToCreateSource }
        var result: [Event] = []
        for stroke in strokes {
            let previous = currentFlags()
            let changed = previous & 0x1e0000 != stroke.flags
            func flags(_ value: UInt64) throws -> Event {
                guard let event = flagsEvent(source, value) else { throw ControllerKeyboardEventCreationError.failedToCreateCGEvent }
                return event
            }
            if changed { result.append(try flags(stroke.flags)) }
            guard let down = keyboardEvent(source, stroke.keyCode, true, stroke.flags, stroke.unicode) else {
                throw ControllerKeyboardEventCreationError.failedToCreateCGEvent
            }
            result.append(down)
            guard let up = keyboardEvent(source, stroke.keyCode, false, stroke.flags, stroke.unicode) else {
                throw ControllerKeyboardEventCreationError.failedToCreateCGEvent
            }
            result.append(up)
            if changed { result.append(try flags(previous)) }
        }
        return result
    }
}

/// Sends without a delay. No extra cancellation check or interval is inserted.
struct ControllerKeyboardImmediateSender<Event> {
    let timestamp: () -> UInt64
    let setTimestamp: (Event, UInt64) -> Void
    let post: (Event, Int32) -> Void
    func send(_ events: [Event], to pid: Int32) {
        for event in events { setTimestamp(event, timestamp()); post(event, pid) }
    }
}

struct ControllerKeyboardHeldEvents<Event> { let down: [Event]; let up: [Event] }
extension ControllerKeyboardHeldEvents: Sendable where Event: Sendable {}

extension ControllerKeyboardEventFactory {
    func makeHolding(_ strokes: [ControllerKeyboardStroke]) throws -> ControllerKeyboardHeldEvents<Event> {
        guard let source = source() else { throw ControllerSynthesizedEventError.failedToCreateSource }
        var down: [Event] = [], up: [Event] = []
        for stroke in strokes {
            let previous = currentFlags()
            let changed = previous & 0x1e0000 != stroke.flags
            func flags(_ value: UInt64) throws -> Event {
                guard let event = flagsEvent(source, value) else { throw ControllerKeyboardEventCreationError.failedToCreateCGEvent }
                return event
            }
            if changed { down.append(try flags(stroke.flags)) }
            guard let press = keyboardEvent(source, stroke.keyCode, true, stroke.flags, stroke.unicode) else { throw ControllerKeyboardEventCreationError.failedToCreateCGEvent }
            down.append(press)
            guard let release = keyboardEvent(source, stroke.keyCode, false, stroke.flags, stroke.unicode) else { throw ControllerKeyboardEventCreationError.failedToCreateCGEvent }
            up.append(release)
            if changed { up.append(try flags(previous)) }
        }
        return .init(down: down, up: up)
    }
}
