import Foundation

/// Visibility precedes count validation; each repeat samples
/// durations afresh. A sleep error propagates without a fabricated release.
@MainActor struct ControllerClickCursorPress {
    let visible: () -> Bool
    let pressed: (Bool) -> Void
    let wait: (Duration) async throws -> Void
    var pressDuration: () -> Duration = { .milliseconds(50) }
    var clickDuration: () -> Duration = { .milliseconds(50) }
    func press(count: Int = 1) async throws {
        guard visible() else { return }
        precondition(count >= 0)
        for index in 0..<count {
            pressed(true)
            try await wait(pressDuration())
            try await wait(clickDuration())
            pressed(false)
            if index+1 < count { try await wait(pressDuration()) }
        }
    }
}
