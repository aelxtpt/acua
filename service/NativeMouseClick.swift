import Foundation

// 0x100709B78: no delay after the final event; an explicit hold on a mouse
// down is at least the interval (or zero when no interval was supplied).
enum NativeMouseClick {
    static let interval: Duration = .milliseconds(50)
    static let pressAnimation: Duration = .milliseconds(50)
    struct Pair<Event> { let down: Event; let up: Event }
    struct Gesture<Event> { let down: Event; let motion: [Event]; let up: Event }

    static func delay(mouseDown: Bool, isLast: Bool, hold: Duration?, interval: Duration?) -> Duration? {
        guard !isLast else { return nil }
        if mouseDown, let hold { return max(hold, interval ?? .zero) }
        return interval
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func deliver<Event>(_ pairs: [Pair<Event>], hold: Duration?,
        cursor: ((Bool) -> Void)?, post: (Event) throws -> Void,
        wait: (Duration) throws -> Void, checkpoint: () throws -> Void,
        recoverUp: (Event) -> Void) throws {
        try deliverGestures(pairs.map { Gesture(down: $0.down, motion: [], up: $0.up) },
            hold: hold, interval: interval, cursor: cursor, post: post, wait: wait,
            checkpoint: checkpoint, recoverUp: recoverUp)
    }

    static func deliverGestures<Event>(_ gestures: [Gesture<Event>], hold: Duration?, interval: Duration?,
        cursor: ((Bool) -> Void)?, post: (Event) throws -> Void,
        wait: (Duration) throws -> Void, checkpoint: () throws -> Void,
        recoverUp: (Event) -> Void) throws {
        var held: Event?, pressed = false
        do {
            for (index, pair) in gestures.enumerated() {
                try checkpoint()
                if let cursor {
                    cursor(true); pressed = true
                    try wait(pressAnimation)
                }
                try checkpoint()
                try post(pair.down); held = pair.up
                if let duration = delay(mouseDown: true, isLast: false, hold: hold, interval: interval) {
                    try wait(duration)
                }
                for event in pair.motion {
                    cursor?(false); pressed = false
                    try checkpoint()
                    try post(event)
                    if let duration = delay(mouseDown: false, isLast: false, hold: hold, interval: interval) {
                        try wait(duration)
                    }
                }
                if cursor != nil { cursor?(false); pressed = false }
                try checkpoint()
                try post(pair.up); held = nil
                if let duration = delay(mouseDown: false, isLast: index == gestures.count - 1, hold: hold, interval: interval) {
                    try wait(duration)
                }
            }
        } catch {
            // Preserve the service's existing release-on-error guarantee. Do
            // not replace the primary request error with a cleanup error.
            if pressed { cursor?(false) }
            if let held { recoverUp(held) }
            throw error
        }
    }
}
