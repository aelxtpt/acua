import Foundation

@MainActor protocol LockScreenController: AnyObject {
    var isLocked: Bool { get }
    func unlock() async throws -> Bool
    func lock()
}

@MainActor protocol LockScreenMonitor: AnyObject {
    func start(onChange: @escaping @MainActor (Bool) -> Void)
    func stop()
}

@MainActor protocol LockScreenGuardian: AnyObject {
    func setPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void)
    func setPendingUnlockPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void)
    func withUnlockGuard(threadID: String, perform: @escaping @MainActor () async throws -> Bool) async throws -> Bool
    func retainAutoUnlockedLease(threadID: String)
    func releaseAutoUnlockedLease(threadID: String)
}

/// Actor-isolated core. Native controller/monitor/guardian adapters and
/// installation in the request callback are separate, still-unfinished work.
@MainActor final class LockScreenAutoUnlockCoordinator {
    enum AccessError: Error, Equatable, CustomStringConvertible {
        case missingThreadID, suppressedUntilManualUnlock, unlockFailed
        var description: String {
            switch self {
            case .missingThreadID:
                return "The Mac is locked and this Computer Use request cannot be associated with an agent thread. Ask the user to unlock the Mac manually before continuing."
            case .suppressedUntilManualUnlock:
                return "The Mac is locked and automatic unlock is paused because physical input was detected. Ask the user to unlock the Mac manually before continuing."
            case .unlockFailed:
                return "The Mac is locked and automatic unlock could not unlock it. Ask the user to unlock the Mac manually before continuing."
            }
        }
    }
    enum SuppressionState: Equatable { case inactive, waitingForRelock, waitingForManualUnlock }
    struct Snapshot: Equatable {
        let activeThreads: Set<String>
        let autoUnlockedThreads: Set<String>
        let attempts: Int
        let suppression: SuppressionState
    }

    private let isAutoUnlockEnabled: () -> Bool
    private let controller: LockScreenController
    private let monitor: LockScreenMonitor
    private let guardian: LockScreenGuardian
    private let maxAttemptsPerLockedEpisode: Int
    private var activeThreads = Set<String>()
    private var autoUnlockedThreads = Set<String>()
    private var attempts = 0
    private var suppression = SuppressionState.inactive
    private var monitorRecovery: Task<Void, Never>?

    init(isAutoUnlockEnabled: @escaping () -> Bool, controller: LockScreenController,
         monitor: LockScreenMonitor, guardian: LockScreenGuardian, maxAttemptsPerLockedEpisode: Int = 2) {
        self.isAutoUnlockEnabled = isAutoUnlockEnabled
        self.controller = controller
        self.monitor = monitor
        self.guardian = guardian
        self.maxAttemptsPerLockedEpisode = maxAttemptsPerLockedEpisode
        guardian.setPhysicalInputHandler { [weak self] in self?.handlePhysicalUserInteraction() }
        guardian.setPendingUnlockPhysicalInputHandler { [weak self] in self?.pendingUnlockPhysicalInput() }
    }

    var hasActiveAutoUnlock: Bool { !autoUnlockedThreads.isEmpty }
    var hasPendingMonitorRecovery: Bool { monitorRecovery != nil }
    var snapshot: Snapshot { .init(activeThreads: activeThreads, autoUnlockedThreads: autoUnlockedThreads,
                                   attempts: attempts, suppression: suppression) }

    func prepareForRequest(threadID: String?) async throws {
        // Observe the episode even when the flag is off.
        let locked = observeLockState()
        guard isAutoUnlockEnabled() else { return }
        guard let threadID else {
            if locked { throw AccessError.missingThreadID }
            return
        }
        activeThreads.insert(threadID)
        updateMonitor()
        if !autoUnlockedThreads.isEmpty, autoUnlockedThreads.insert(threadID).inserted {
            guardian.retainAutoUnlockedLease(threadID: threadID)
        }
        guard locked else { return }
        guard suppression == .inactive else { throw AccessError.suppressedUntilManualUnlock }

        let didUnlock = try await withUnlockGuard(threadID: threadID) { [self] in
            let result = try await unlockWithinEpisode()
            if result { autoUnlockedThreads.insert(threadID) }
            return result
        }
        guard didUnlock else { throw AccessError.unlockFailed }
    }

    private func withUnlockGuard(threadID: String,
                                 perform: @escaping @MainActor () async throws -> Bool) async throws -> Bool {
        // The box records a successful operation result, not merely entry into
        // the operation. Guardian failure after success requires a relock.
        var operationSucceeded = false
        do {
            return try await guardian.withUnlockGuard(threadID: threadID) {
                let result = try await perform()
                operationSucceeded = result
                return result
            }
        } catch {
            if operationSucceeded {
                autoUnlockedThreads.removeAll()
                suppression = .waitingForRelock
                _ = observeLockState()
                updateMonitor()
                if !controller.isLocked { controller.lock() }
            }
            throw AccessError.unlockFailed
        }
    }

    func agentTurnEnded(threadID: String) {
        activeThreads.remove(threadID)
        updateMonitor()
        if autoUnlockedThreads.remove(threadID) != nil {
            guardian.releaseAutoUnlockedLease(threadID: threadID)
        }
    }

    func handlePhysicalUserInteraction() {
        guard !autoUnlockedThreads.isEmpty else { return }
        autoUnlockedThreads.removeAll()
        suppression = .waitingForRelock
        _ = observeLockState()
        updateMonitor()
    }

    private func pendingUnlockPhysicalInput() {
        guard !autoUnlockedThreads.isEmpty else { return }
        autoUnlockedThreads.removeAll()
        suppression = .waitingForRelock
        _ = observeLockState()
        updateMonitor()
        if !controller.isLocked { controller.lock() }
    }

    @discardableResult private func observeLockState() -> Bool {
        let locked = controller.isLocked
        updateEpisode(locked: locked)
        return locked
    }

    private func updateEpisode(locked: Bool) {
        if locked {
            if suppression == .waitingForRelock { suppression = .waitingForManualUnlock }
        } else {
            attempts = 0
            if suppression == .waitingForManualUnlock {
                suppression = .inactive
                updateMonitor()
            }
        }
    }

    private func updateMonitor() {
        if !activeThreads.isEmpty || suppression != .inactive {
            monitor.start { [weak self] locked in self?.lockStateChanged(locked) }
        } else { monitor.stop() }
    }

    private func lockStateChanged(_ locked: Bool) {
        // The monitor supplies this sample; it is not replaced with a fresh
        // controller query. Only the recovery task samples the controller.
        updateEpisode(locked: locked)
        if locked, !activeThreads.isEmpty, monitorRecovery == nil {
            monitorRecovery = Task { [weak self] in
                guard let self else { return }
                defer { self.monitorRecovery = nil }
                await self.recoverAfterRelock()
            }
        }
    }

    private func recoverAfterRelock() async {
        guard observeLockState(), isAutoUnlockEnabled(), suppression == .inactive,
              let thread = activeThreads.first else { return }
        let threads = activeThreads
        do {
            _ = try await withUnlockGuard(threadID: thread) { [self] in
                let result = try await unlockWithinEpisode()
                if result { autoUnlockedThreads.formUnion(threads) }
                return result
            }
        } catch {
            // Monitor recovery logs this failure, without propagating it to an
            // unrelated request. Its task slot is cleared on return.
        }
    }

    private func unlockWithinEpisode() async throws -> Bool {
        // Trust the post-call lock sample rather than the controller's return
        // Boolean. Do not insert a fresh pre-unlock check or reset the counter
        // on an error.
        while attempts < maxAttemptsPerLockedEpisode {
            let priorAttempt = attempts
            attempts += 1
            _ = try await controller.unlock()
            if !observeLockState() { return priorAttempt < maxAttemptsPerLockedEpisode }
        }
        return false
    }
}
