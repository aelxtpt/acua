import AppKit
import CoreGraphics
import Combine

enum SystemLockScreenSession {
    static func isLocked(_ dictionary: [String: Any]?) -> Bool {
        dictionary?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    static func readLocked() -> Bool { isLocked(CGSessionCopyCurrentDictionary() as? [String: Any]) }
}

/// Removal is explicit. The state monitor does not remove its
/// distributed observers in deinit; its owner must call stop.
@MainActor struct LockScreenNotificationRegistration {
    let remove: @MainActor () -> Void
}

@MainActor struct LockScreenObservationEnvironment {
    var readLocked: () -> Bool
    var observe: (String, @escaping @MainActor () -> Void) -> LockScreenNotificationRegistration
    var sleep: @MainActor (Duration) async throws -> Void

    static var native: Self {
        .init(readLocked: SystemLockScreenSession.readLocked, observe: { name, handler in
            let center = DistributedNotificationCenter.default()
            let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            return .init(remove: { center.removeObserver(token) })
        }, sleep: { try await Task.sleep(for: $0, clock: .continuous) })
    }
}

@MainActor final class SystemLockScreenMonitor: LockScreenMonitor, LockScreenCleanupMonitor {
    static let stateNotifications = [
        "com.apple.screenIsLocked", "com.apple.sessionagent.screenIsLocked",
        "com.apple.screenIsUnlocked", "com.apple.sessionagent.screenIsUnlocked",
    ]
    static let settledNotifications = [
        "com.apple.screenLockUIIsShown", "com.apple.sessionagent.screenLockUIIsShown",
    ]
    private let environment: LockScreenObservationEnvironment
    private let settleDelay: Duration
    private let fallbackDelay: Duration
    private var registrations = [LockScreenNotificationRegistration]()
    private var lastLocked: Bool?
    private var handler: (@MainActor (Bool) -> Void)?

    init(lockUISettleDelay: Duration = .milliseconds(1500), lockUIFallbackDelay: Duration = .seconds(3),
         environment: LockScreenObservationEnvironment = .native) {
        self.settleDelay = lockUISettleDelay
        self.fallbackDelay = lockUIFallbackDelay
        self.environment = environment
    }

    var isMonitoring: Bool { !registrations.isEmpty }
    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        guard registrations.isEmpty else { return }
        handler = onChange
        lastLocked = environment.readLocked()
        registrations = Self.stateNotifications.map { name in
            environment.observe(name) { [weak self] in self?.stateChanged() }
        }
    }

    func stop() {
        for registration in registrations { registration.remove() }
        registrations.removeAll()
        lastLocked = nil
        handler = nil
    }

    private func stateChanged() {
        let locked = environment.readLocked()
        guard lastLocked == nil || lastLocked != locked else { return }
        lastLocked = locked
        handler?(locked)
    }

    func observeLockUISettled(_ completion: @escaping @MainActor () -> Void) -> AnyCancellable {
        let observation = SystemLockScreenSettleObservation(environment: environment,
            settleDelay: settleDelay, fallbackDelay: fallbackDelay, onSettled: completion)
        observation.start()
        return AnyCancellable {
            if Thread.isMainThread { MainActor.assumeIsolated { observation.cancel() } }
            else { Task { @MainActor in observation.cancel() } }
        }
    }
}

@MainActor private final class SystemLockScreenSettleObservation {
    private let environment: LockScreenObservationEnvironment
    private let settleDelay: Duration
    private let fallbackDelay: Duration
    private let onSettled: @MainActor () -> Void
    private var registrations = [LockScreenNotificationRegistration]()
    private var fallbackTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var notificationReceived = false
    private var completed = false
    private var cancelled = false

    init(environment: LockScreenObservationEnvironment, settleDelay: Duration, fallbackDelay: Duration,
         onSettled: @escaping @MainActor () -> Void) {
        self.environment = environment
        self.settleDelay = settleDelay
        self.fallbackDelay = fallbackDelay
        self.onSettled = onSettled
    }
    func start() {
        guard registrations.isEmpty else { return }
        registrations = SystemLockScreenMonitor.settledNotifications.map { name in
            environment.observe(name) { [weak self] in self?.lockUIShown() }
        }
        fallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await environment.sleep(fallbackDelay) } catch { return }
            finish()
        }
    }
    private func lockUIShown() {
        guard !cancelled, !completed, !notificationReceived else { return }
        notificationReceived = true
        fallbackTask?.cancel()
        fallbackTask = nil
        settleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await environment.sleep(settleDelay) } catch { return }
            finish()
        }
    }
    private func finish() {
        guard !Task.isCancelled, !cancelled, !completed else { return }
        completed = true
        cleanup()
        onSettled()
    }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        cleanup()
    }
    private func cleanup() {
        for registration in registrations { registration.remove() }
        registrations.removeAll()
        fallbackTask?.cancel()
        fallbackTask = nil
        settleTask?.cancel()
        settleTask = nil
    }
}
