import Foundation
import Combine

@MainActor protocol LockScreenOverlayPresenter: AnyObject {
    func present()
    func dismiss()
}

@MainActor protocol LockScreenPhysicalInputMonitor: AnyObject {
    func start(onInput: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor protocol LockScreenCleanupMonitor: AnyObject {
    func observeLockUISettled(_ completion: @escaping @MainActor () -> Void) -> AnyCancellable
}

/// Owns independent active and settling overlay assertions.
/// Cancellation from another thread is handed back to MainActor.
@MainActor private final class LockScreenOverlayAssertions {
    private let presenter: LockScreenOverlayPresenter
    private var ids = Set<UUID>()
    init(_ presenter: LockScreenOverlayPresenter) { self.presenter = presenter }
    func acquire() -> AnyCancellable {
        let first = ids.isEmpty, id = UUID()
        ids.insert(id)
        if first { presenter.present() }
        return AnyCancellable { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.release(id) }
            } else {
                Task { @MainActor [weak self] in self?.release(id) }
            }
        }
    }
    private func release(_ id: UUID) {
        guard ids.remove(id) != nil else { return }
        if ids.isEmpty { presenter.dismiss() }
    }
}

/// In-process lock screen guardian. Native adapters and service installation are
/// pending; tests supply owned controller/overlay/input/settling observations.
@MainActor final class LockScreenGuardianCoordinator: LockScreenGuardian {
    struct Snapshot: Equatable {
        let pendingThreads: Set<String>
        let autoUnlockedThreads: Set<String>
        let hasActiveOverlay: Bool
        let hasSettlingOverlay: Bool
        let hasSettlingObservation: Bool
        let cleanupCompletions: Int
    }
    private let controller: LockScreenController
    private let monitor: LockScreenCleanupMonitor
    private let physicalInput: LockScreenPhysicalInputMonitor
    private let overlays: LockScreenOverlayAssertions
    private var physicalInputHandler: (@MainActor () -> Void)?
    private var pendingUnlockPhysicalInputHandler: (@MainActor () -> Void)?
    private var pendingThreads = Set<String>()
    private var autoUnlockedThreads = Set<String>()
    private var activeOverlay: AnyCancellable?
    private var settlingOverlay: AnyCancellable?
    private var settlingObservation: AnyCancellable?
    private var cleanupCompletions = [@MainActor () -> Void]()

    init(controller: LockScreenController, monitor: LockScreenCleanupMonitor,
         overlayPresenter: LockScreenOverlayPresenter, physicalInput: LockScreenPhysicalInputMonitor) {
        self.controller = controller
        self.monitor = monitor
        self.physicalInput = physicalInput
        self.overlays = LockScreenOverlayAssertions(overlayPresenter)
    }

    var snapshot: Snapshot {
        .init(pendingThreads: pendingThreads, autoUnlockedThreads: autoUnlockedThreads,
              hasActiveOverlay: activeOverlay != nil, hasSettlingOverlay: settlingOverlay != nil,
              hasSettlingObservation: settlingObservation != nil, cleanupCompletions: cleanupCompletions.count)
    }
    func setPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) { physicalInputHandler = handler }
    func setPendingUnlockPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) { pendingUnlockPhysicalInputHandler = handler }

    func withUnlockGuard(threadID: String, perform: @escaping @MainActor () async throws -> Bool) async throws -> Bool {
        try await beginUnlockGuard(threadID: threadID)
        do {
            let result = try await perform()
            completeUnlockGuard(threadID: threadID, didUnlock: result)
            return result
        } catch {
            completeUnlockGuard(threadID: threadID, didUnlock: false)
            throw error
        }
    }

    func beginUnlockGuard(threadID: String) async throws {
        pendingThreads.insert(threadID)
        physicalInput.start { [weak self] in self?.physicalInputDetected() }
        if activeOverlay == nil { activeOverlay = overlays.acquire() }
        if settlingOverlay != nil {
            settlingObservation = nil
            settlingOverlay = nil
            cleanupCompletions.removeAll()
        }
    }

    func completeUnlockGuard(threadID: String, didUnlock: Bool) {
        let wasPending = pendingThreads.remove(threadID) != nil
        if wasPending && didUnlock {
            autoUnlockedThreads.insert(threadID)
            if activeOverlay == nil { activeOverlay = overlays.acquire() }
        } else { releaseIdleResources() }
    }

    func retainAutoUnlockedLease(threadID: String) {
        autoUnlockedThreads.insert(threadID)
        if activeOverlay == nil { activeOverlay = overlays.acquire() }
    }

    func releaseAutoUnlockedLease(threadID: String) {
        guard autoUnlockedThreads.remove(threadID) != nil,
              autoUnlockedThreads.isEmpty, pendingThreads.isEmpty else { return }
        requestRelock(onCleanupCompleted: nil)
    }

    func serviceConnectionInvalidated(onCleanupCompleted: (@MainActor () -> Void)? = nil) {
        physicalInputHandler = nil
        pendingUnlockPhysicalInputHandler = nil
        if !pendingThreads.isEmpty || !autoUnlockedThreads.isEmpty || settlingOverlay != nil {
            pendingThreads.removeAll()
            autoUnlockedThreads.removeAll()
            requestRelock(onCleanupCompleted: onCleanupCompleted)
        } else { onCleanupCompleted?() }
    }

    private func releaseIdleResources() {
        guard pendingThreads.isEmpty, autoUnlockedThreads.isEmpty else { return }
        physicalInput.stop()
        activeOverlay = nil
    }

    private func physicalInputDetected() {
        let wasPending = !pendingThreads.isEmpty
        guard wasPending || !autoUnlockedThreads.isEmpty else { return }
        pendingThreads.removeAll()
        autoUnlockedThreads.removeAll()
        requestRelock(onCleanupCompleted: nil)
        if wasPending { pendingUnlockPhysicalInputHandler?() }
        else { physicalInputHandler?() }
    }

    private func requestRelock(onCleanupCompleted: (@MainActor () -> Void)?) {
        physicalInput.stop()
        if controller.isLocked {
            activeOverlay = nil
            if settlingOverlay != nil {
                if let onCleanupCompleted { cleanupCompletions.append(onCleanupCompleted) }
            } else { onCleanupCompleted?() }
        } else {
            startSettling(onCleanupCompleted: onCleanupCompleted)
            activeOverlay = nil
            controller.lock()
        }
    }

    private func startSettling(onCleanupCompleted: (@MainActor () -> Void)?) {
        if let onCleanupCompleted { cleanupCompletions.append(onCleanupCompleted) }
        guard settlingOverlay == nil else { return }
        settlingOverlay = overlays.acquire()
        settlingObservation = monitor.observeLockUISettled { [weak self] in self?.finishSettling() }
    }

    private func finishSettling() {
        guard settlingOverlay != nil, autoUnlockedThreads.isEmpty else { return }
        // Log an unlocked fallback sample but still finish this
        // observation; it does not invent another lock request here.
        _ = controller.isLocked
        settlingObservation = nil
        settlingOverlay = nil
        let callbacks = cleanupCompletions
        cleanupCompletions.removeAll()
        for callback in callbacks { callback() }
    }
}
