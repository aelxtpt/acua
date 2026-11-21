import Foundation

@MainActor struct LockScreenReturnEventFactory<Source, Event> {
    var source: () -> Source?
    var currentFlags: () -> UInt64
    var flagsEvent: (Source) -> Event?
    var keyboardEvent: (Source, UInt16, Bool) -> Event?
    var setFlags: (Event, UInt64) -> Void
    var setUnicode: (Event, [UInt16]) -> Void

    enum CreationError: Error { case source, event }
    func make() throws -> [Event] {
        guard let source = source() else { throw CreationError.source }
        let previous = currentFlags(), changed = previous & 0x1e0000 != 0
        var events = [Event]()
        if changed {
            guard let flags = flagsEvent(source) else { throw CreationError.event }
            setFlags(flags, 0); events.append(flags)
        }
        guard let down = keyboardEvent(source, 36, true) else { throw CreationError.event }
        setFlags(down, 0); setUnicode(down, [13]); events.append(down)
        guard let up = keyboardEvent(source, 36, false) else { throw CreationError.event }
        setFlags(up, 0); setUnicode(up, [13]); events.append(up)
        if changed {
            guard let flags = flagsEvent(source) else { throw CreationError.event }
            setFlags(flags, previous); events.append(flags)
        }
        return events
    }
}

@MainActor struct LockScreenGlobalEventSender<Event> {
    var now: () -> UInt64
    var setTimestamp: (Event, UInt64) -> Void
    var post: (Event) -> Void
    func send(_ events: [Event]) {
        // The nil-delay sender neither inserts waits nor checks cancellation.
        for event in events { setTimestamp(event, now()); post(event) }
    }
}
