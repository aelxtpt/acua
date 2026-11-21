import AppKit
import CoreGraphics
import Darwin

@MainActor struct LockScreenNativeEvents {
    enum Error: Swift.Error { case eventCreation, windowLocationUnavailable }
    // Integration must supply the service's shared sequence, not a second counter.
    let nextEventNumber: () -> Int64
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        ControllerWindowServerOperations.native.setLocation($0, $1)
    }

    func makeClick(_ click: LockScreenRevealClick) throws -> [CGEvent] {
        let number = nextEventNumber()
        guard let setWindowLocation = Self.setWindowLocation else { throw Error.windowLocationUnavailable }
        return try LockScreenMouseEventPlan.events(click,number:number).map { plan in
            guard let event = NSEvent.mouseEvent(with: plan.kind == .down ? .leftMouseDown : .leftMouseUp,
                location: plan.global, modifierFlags: [], timestamp: 0, windowNumber: Int(plan.windowID),
                context: nil, eventNumber: Int(plan.number), clickCount: 1, pressure: 1)?.cgEvent else {
                throw Error.eventCreation
            }
            event.flags = []; event.location = click.point
            event.setIntegerValueField(.mouseEventButtonNumber,value:0)
            event.setIntegerValueField(.mouseEventSubtype,value:3)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(click.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(click.windowID))
            setWindowLocation(event,plan.local)
            return event
        }
    }
    func makeReturn() throws -> [CGEvent] {
        try LockScreenReturnEventFactory<CGEventSource,CGEvent>(source: { CGEventSource(stateID:.hidSystemState) },
            currentFlags: { CGEventSource.flagsState(.combinedSessionState).rawValue },
            flagsEvent: { source in
                guard let event = CGEvent(source:source) else { return nil }
                event.type = .flagsChanged; return event
            }, keyboardEvent: { CGEvent(keyboardEventSource:$0,virtualKey:$1,keyDown:$2) },
            setFlags: { $0.flags = .init(rawValue:$1) }, setUnicode: { event, units in
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress!) }
            }).make()
    }
    func send(_ events: [CGEvent]) {
        LockScreenGlobalEventSender<CGEvent>(now: { DispatchTime.now().uptimeNanoseconds },
            setTimestamp: { $0.timestamp = $1 }, post: { $0.post(tap:.cgSessionEventTap) }).send(events)
    }
}
