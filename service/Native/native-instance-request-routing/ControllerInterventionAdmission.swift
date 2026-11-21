import Foundation

enum ControllerInterventionAdmissionError: Error, Equatable {
    case userIntervened(String)
}

struct ControllerInterventionWaitClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void
    static var native: Self {
        let origin = ContinuousClock.now
        return .init(now: { origin.duration(to: .now) }, sleep: { try await ContinuousClock().sleep(for: $0) })
    }
}

/// The quiet deadline is wall time; the maximum
/// wait is monotonic. A new intervention never restarts that maximum wait.
struct ControllerInterventionAdmission: Sendable {
    static let maximumWait: Duration = .seconds(100)
    static let pollingInterval: Duration = .milliseconds(250)
    let read: @Sendable () -> ControllerUserIntervention?
    let now: @Sendable () -> Date
    let clock: ControllerInterventionWaitClock

    func wait(timeout: Duration = maximumWait, pollingInterval: Duration = pollingInterval) async -> ControllerUserIntervention? {
        let end = clock.now() + timeout
        while let value = read() {
            // Re-read once more after a missing/expired deadline,
            // but return the inspected snapshot when the maximum wait expires.
            if !value.isDebouncing(at: now()) { return read() }
            if clock.now() >= end { return value }
            let delay = min(pollingInterval, end - clock.now())
            // Discard a sleep error and inspect state again; the error is
            // never turned into a thrown cancellation.
            do { try await clock.sleep(delay) } catch {}
        }
        return read()
    }
    func check(requestedIdentifier: String, allowsStateRequery: Bool) async throws {
        guard let initial = read() else { return }
        let current: ControllerUserIntervention
        if initial.isDebouncing(at: now()) {
            current = await wait() ?? initial
        } else {
            current = initial
        }
        if current.isDebouncing(at: now()) {
            throw ControllerInterventionAdmissionError.userIntervened(
                "The user is still interacting with '\(requestedIdentifier)'. Wait 5 seconds and retry.")
        }
        if current.requiresRequery && !allowsStateRequery {
            throw ControllerInterventionAdmissionError.userIntervened(
                "The user changed '\(requestedIdentifier)'. Re-query the latest state with `get_app_state` before sending more actions.")
        }
    }
}

extension ControllerApplicationInstanceManager {
    func checkUserIntervention(for identifier: String, requestedIdentifier: String, allowsStateRequery: Bool,
                               clock: ControllerInterventionWaitClock = .native) async throws {
        try await ControllerInterventionAdmission(read: { self.userInterruptedIntervention(for: identifier) },
            now: environment.now, clock: clock).check(requestedIdentifier: requestedIdentifier, allowsStateRequery: allowsStateRequery)
    }
}
