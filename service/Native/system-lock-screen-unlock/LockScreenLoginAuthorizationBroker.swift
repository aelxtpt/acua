import Foundation

@MainActor final class LockScreenLoginAuthorizationAttempt: LockScreenLoginAttempt {
    private(set) var resolution: LockScreenLoginResolution?
    private var waiters = [CheckedContinuation<LockScreenLoginResolution, Never>]()
    private let onResolution: (LockScreenLoginAuthorizationAttempt) -> Void
    private let sleep: (Duration) async throws -> Void

    init(sleep: @escaping (Duration) async throws -> Void,
         onResolution: @escaping (LockScreenLoginAuthorizationAttempt) -> Void) {
        self.sleep = sleep; self.onResolution = onResolution
    }
    func revoke() { resolve(.revoked) }
    func resolve(_ resolution: LockScreenLoginResolution) {
        guard self.resolution == nil else { return }
        self.resolution = resolution
        onResolution(self)
        let callbacks = waiters
        waiters.removeAll()
        for callback in callbacks { callback.resume(returning: resolution) }
    }
    func waitForResolution(timeout: Duration) async -> LockScreenLoginResolution {
        if let resolution { return resolution }
        let sleep = self.sleep
        let timer = Task { @MainActor [weak self] in
            do { try await sleep(timeout) } catch { return }
            self?.resolve(.timedOut)
        }
        defer { timer.cancel() }
        // The attempt itself does not add cancellation revocation. The controller
        // owns that handler. Cancelled direct waiters remain until resolution.
        return await withCheckedContinuation { continuation in
            if let resolution { continuation.resume(returning: resolution) }
            else { waiters.append(continuation) }
        }
    }
}

@MainActor final class LockScreenLoginAuthorizationBroker: LockScreenLoginApproving {
    private(set) var activeAttempt: LockScreenLoginAuthorizationAttempt?
    private let sleep: (Duration) async throws -> Void
    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0, clock: .continuous) }) {
        self.sleep = sleep
    }
    func beginLoginAuthorizationAttempt() -> any LockScreenLoginAttempt { beginAttempt() }
    func beginAttempt() -> LockScreenLoginAuthorizationAttempt {
        let attempt = LockScreenLoginAuthorizationAttempt(sleep: sleep) { [weak self] completed in
            guard let self, self.activeAttempt === completed else { return }
            self.activeAttempt?.revoke()
            self.activeAttempt = nil
        }
        activeAttempt?.revoke()
        activeAttempt = attempt
        return attempt
    }
    func consumePendingLoginAuthorizationAttempt() -> Bool {
        guard let attempt = activeAttempt, attempt.resolution == nil else { return false }
        attempt.resolve(.approved)
        return true
    }
}
