import Foundation

enum SystemSettingsPollError: Error, CustomNSError, Sendable {
    case timeoutReached
    static var errorDomain: String { "AccessibilitySupport.PollError" }
    var errorCode: Int { 0 }
    var errorUserInfo: [String:Any] { [:] }
}
enum SystemSettingsPoll {
    struct Environment: Sendable {
        let now: @Sendable () -> Date
        let sleep: @Sendable (Duration) async throws -> Void
        static let native = Self(now:{ Date.now },sleep:{ duration in
            let clock=ContinuousClock()
            try await clock.sleep(until:clock.now.advanced(by:duration),tolerance:nil)
        })
    }
    // AccessibilitySupport788774 uses wall Date for timeout, ContinuousClock
    // for sleep, checks elapsed <= timeout before the condition, and does not
    // insert a cancellation check before a successful condition.
    static func untilTrue(timeout: Double, delay: Double, environment: Environment = .native,
                          condition: @escaping @Sendable () async -> Bool) async throws {
        let started=environment.now()
        while environment.now().timeIntervalSince(started) <= timeout {
            if await condition() { return }
            try await environment.sleep(.seconds(delay))
        }
        throw SystemSettingsPollError.timeoutReached
    }
}
