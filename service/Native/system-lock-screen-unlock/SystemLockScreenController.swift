import Foundation

enum LockScreenLoginResolution: UInt8, Sendable { case approved = 0, revoked = 1, timedOut = 2 }

@MainActor protocol LockScreenLoginAttempt: AnyObject, Sendable {
    func revoke()
    func waitForResolution(timeout: Duration) async -> LockScreenLoginResolution
}
@MainActor protocol LockScreenLoginApproving: AnyObject, Sendable {
    func beginLoginAuthorizationAttempt() -> any LockScreenLoginAttempt
}
@MainActor protocol LockScreenAXInteracting {
    associatedtype Element
    func findPasswordField() -> Element?
    func findPasswordEntryRevealCandidate() -> Element?
    func revealPasswordEntry(_ candidate: Element) async throws -> Bool
    func clearPasswordField(_ field: Element) throws
    func submitReturn() async -> Bool
}

@MainActor struct LockScreenUnlockEnvironment {
    var isAccessibilityTrusted: () -> Bool
    var isLocked: () -> Bool
    var lock: () -> Void
    var now: () -> Duration
    var sleep: (Duration) async throws -> Void
}

/// Unlock controller core. Native AX and login transport are separate adapters;
/// this staged type is exercised only with owned providers, not installed.
@MainActor final class SystemLockScreenController<AX: LockScreenAXInteracting>: LockScreenController {
    private enum Submission { case resolved(LockScreenLoginResolution), failed }
    let timeout: Duration
    let pollInterval: Duration
    let submitDelay: Duration
    let verificationDelay: Duration
    private let ax: AX
    private let environment: LockScreenUnlockEnvironment
    private let brokerFactory: () -> any LockScreenLoginApproving

    init(timeout: Duration = .seconds(10), pollInterval: Duration = .milliseconds(250),
         submitDelay: Duration = .milliseconds(500), verificationDelay: Duration = .seconds(2),
         environment: LockScreenUnlockEnvironment, accessibilityInteractor: AX,
         loginAuthorizationBrokerFactory: @escaping () -> any LockScreenLoginApproving) {
        self.timeout = timeout; self.pollInterval = pollInterval
        self.submitDelay = submitDelay; self.verificationDelay = verificationDelay
        self.environment = environment; ax = accessibilityInteractor; brokerFactory = loginAuthorizationBrokerFactory
    }
    var isLocked: Bool { environment.isLocked() }
    func lock() { environment.lock() }

    func unlock() async throws -> Bool {
        try Task.checkCancellation()
        // Sample both before either early return; unlocked also returns false.
        let trusted = environment.isAccessibilityTrusted()
        let locked = environment.isLocked()
        guard trusted, locked else { return false }
        let deadline = environment.now() + timeout
        var field = ax.findPasswordField()
        while field == nil && environment.now() < deadline {
            try Task.checkCancellation()
            if let candidate = ax.findPasswordEntryRevealCandidate() {
                // Both false and a thrown reveal are logged, then polling resumes.
                do { _ = try await ax.revealPasswordEntry(candidate) } catch {}
            }
            try await environment.sleep(pollInterval)
            field = ax.findPasswordField()
        }
        guard let field else { return false }
        do { try ax.clearPasswordField(field) }
        catch { return false }
        try Task.checkCancellation()
        try await environment.sleep(submitDelay)
        let attempt = brokerFactory().beginLoginAuthorizationAttempt()
        let verificationDeadline = environment.now() + verificationDelay
        // Cancellation schedules revocation on the same actor.
        let submission: Submission = await withTaskCancellationHandler {
            guard await ax.submitReturn() else { attempt.revoke(); return .failed }
            let remaining = remaining(until: verificationDeadline)
            return .resolved(await attempt.waitForResolution(timeout: remaining))
        } onCancel: {
            Task { @MainActor in attempt.revoke() }
        }
        guard case .resolved(.approved) = submission else { return false }
        let remaining = remaining(until: verificationDeadline)
        if remaining > .zero { try await environment.sleep(remaining) }
        return !environment.isLocked()
    }

    private func remaining(until deadline: Duration) -> Duration {
        // Sample now twice when the first sample is before the deadline.
        environment.now() < deadline ? deadline - environment.now() : .zero
    }
}
