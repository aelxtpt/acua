import AppKit
import ApplicationServices
import Foundation

@MainActor struct ControllerNativeClickEvents {
    typealias Event = ControllerFocusNativeEvent
    let windowServer: ControllerNativeWindowServer
    var numbers: SynthesizedEventNumberSequence = SynthesizedEventNumbers.shared

    func mouse(at point: CGPoint, target: ControllerMouseEventTarget<ControllerNativeElementContext.Node>, options: ControllerLowerClickOptions, flags: UInt64) throws -> [Event] {
        guard options.count > 0 else { throw ControllerLowerClickFailure.invalidCount }
        let down: NSEvent.EventType = options.button == 0 ? .leftMouseDown : (options.button == 1 ? .rightMouseDown : .otherMouseDown)
        let up: NSEvent.EventType = options.button == 0 ? .leftMouseUp : (options.button == 1 ? .rightMouseUp : .otherMouseUp)
        var result: [Event] = []
        for count in 1...options.count {
            let number = numbers.next()
            for type in [down, up] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: Int(target.windowID), context: nil, eventNumber: Int(number), clickCount: count, pressure: 1)?.cgEvent else {
                    throw ControllerLowerClickFailure.cannotCreateEvent
                }
                event.flags = .init(rawValue: flags)
                event.location = point
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(options.button))
                event.setIntegerValueField(.mouseEventSubtype, value: 3)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
                var local = CGPoint(x: event.location.x - target.windowBounds.minX, y: event.location.y - target.windowBounds.minY)
                if target.windowUsesFlippedCoordinates { local.y = target.windowBounds.height - local.y }
                windowServer.setLocation(event, local)
                result.append(.init(event: event))
            }
        }
        return result
    }
    func held(_ key: ControllerHeldClickKey) throws -> ControllerHeldEventPair<Event>? {
        try ControllerHeldClickEventFactory<CGEventSource, Event>(source: { CGEventSource(stateID: .hidSystemState) },
            currentFlags: { CGEventSource.flagsState(.combinedSessionState).rawValue }, flagsEvent: { source, flags in
                guard let event = CGEvent(source: source) else { return nil }
                event.type = .flagsChanged; event.flags = .init(rawValue: flags); return .init(event: event)
            }, keyboardEvent: { source, code, down, flags in
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
                event.flags = .init(rawValue: flags); return .init(event: event)
            }).make(key)
    }
    static func post(_ event: Event, pid: Int32) {
        event.event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.event.postToPid(pid)
    }
}
