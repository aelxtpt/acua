import Foundation

/// nextEventNumber returns the old signed Int64,
/// then increments with overflow checking. Copies of a consumer share one owner.
final class SynthesizedEventNumberSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(initialValue: Int64 = 0) { value = initialValue }
    func next() -> Int64 {
        lock.withLock {
            let result = value
            value = result + 1
            return result
        }
    }
}

enum SynthesizedMouseGesture {
    /// The second number is acquired after a successful press factory, before
    /// constructing motion. Release reuses the first number. A failed press
    /// must not consume a motion number; later failures do not roll either back.
    static func drag<Event>(pressNumber: Int64, nextMotionNumber: () -> Int64,
        press: (Int64) throws -> Event, motion: (Int64) throws -> [Event],
        release: (Int64) throws -> Event) rethrows -> (down: Event, motion: [Event], up: Event) {
        let down = try press(pressNumber)
        let motionNumber = nextMotionNumber()
        let movement = try motion(motionNumber)
        return (down, movement, try release(pressNumber))
    }
}
