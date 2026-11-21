import CoreGraphics

/// Construct all six events before posting any of them.
enum SystemLockScreenLockAction {
    struct Key: Equatable {
        let code: UInt16
        let down: Bool
        let flags: UInt64?
    }
    static let keys: [Key] = [
        .init(code: 55, down: true, flags: 0x100000),
        .init(code: 59, down: true, flags: 0x140000),
        .init(code: 12, down: true, flags: 0x140000),
        .init(code: 12, down: false, flags: 0x140000),
        .init(code: 59, down: false, flags: 0x100000),
        .init(code: 55, down: false, flags: nil),
    ]
    struct Provider<Source, Event> {
        var source: () -> Source?
        var create: (Source, UInt16, Bool) -> Event?
        var setFlags: (Event, UInt64) -> Void
        var post: (Event) -> Void
    }
    static func perform<Source, Event>(_ provider: Provider<Source, Event>) {
        guard let source = provider.source() else { return }
        var events = [Event]()
        for key in keys {
            guard let event = provider.create(source, key.code, key.down) else { return }
            events.append(event)
        }
        for (event, key) in zip(events, keys) {
            if let flags = key.flags { provider.setFlags(event, flags) }
        }
        for event in events { provider.post(event) }
    }
    static func performNative() {
        perform(Provider<CGEventSource, CGEvent>(source: { CGEventSource(stateID: .hidSystemState) },
            create: { CGEvent(keyboardEventSource: $0, virtualKey: $1, keyDown: $2) },
            setFlags: { $0.flags = CGEventFlags(rawValue: $1) },
            post: { $0.post(tap: .cgSessionEventTap) }))
    }
}
