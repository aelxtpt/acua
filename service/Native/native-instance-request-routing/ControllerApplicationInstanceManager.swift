import Foundation

/// The three collections share one lock, while task cancellation
/// and UI callbacks happen outside it. Keys are opaque canonical target strings;
/// stop and interruption entry points must not silently resolve bundle aliases.
final class ControllerApplicationInstanceManager<Controller: Sendable>: @unchecked Sendable {
    typealias Instance = ControllerApplicationInstance<Controller>
    struct Environment: Sendable {
        let isActive: @Sendable (Controller) -> Bool
        let isTerminated: @Sendable (Controller) -> Bool
        let activeCountChanged: @Sendable (Int) -> Void
        let setCursorActivity: @MainActor @Sendable (Controller, UInt8) -> Void
        let postUserInterruption: @MainActor @Sendable (Controller) -> Void
        let now: @Sendable () -> Date
        let sleep: @Sendable (Duration) async throws -> Void
    }
    private struct State {
        var instances: [Instance] = []
        var interventions: [String: ControllerInterventionReason] = [:]
        var debounceTasks: [String: Task<Void, Never>] = [:]
    }
    let environment: Environment
    let debounceDuration: Duration
    private let lock = NSLock()
    private var state = State()

    init(debounceDuration: Duration = .seconds(5), environment: Environment) {
        self.debounceDuration = debounceDuration; self.environment = environment
    }
    var instances: [Instance] { lock.withLock { state.instances } }
    var activeInstances: [Instance] {
        lock.withLock { state.instances.filter { environment.isActive($0.controller) } }
    }
    func instance(for identifier: String) -> Instance? {
        lock.withLock { state.instances.first { $0.applicationTarget.identifier == identifier } }
    }
    func setInstance(_ instance: Instance) {
        lock.withLock {
            state.instances.removeAll { $0.applicationTarget.identifier == instance.applicationTarget.identifier }
            state.instances.append(instance)
        }
        updateActiveCount()
    }
    func removeInstance(for identifier: String) {
        let previous = lock.withLock {
            let previous = state.instances
            state.instances.removeAll { $0.applicationTarget.identifier == identifier }
            return previous
        }
        withExtendedLifetime(previous) {}
        updateActiveCount()
    }
    func updateActiveCount() { environment.activeCountChanged(activeInstances.count) }
    func interventionReason(for identifier: String) -> ControllerInterventionReason? {
        lock.withLock { state.interventions[identifier] }
    }
    func userInterruptedIntervention(for identifier: String) -> ControllerUserIntervention? {
        guard case .userInterrupted(let value) = interventionReason(for: identifier) else { return nil }
        return value
    }
    func wasStoppedByUser(for identifier: String) -> Bool {
        interventionReason(for: identifier) == .stoppedByUser
    }
    private func removeDebounceTask(for identifier: String) -> Task<Void, Never>? {
        lock.withLock { state.debounceTasks.removeValue(forKey: identifier) }
    }
    private func setIntervention(_ reason: ControllerInterventionReason, for identifier: String) {
        // Setting stopped cancels a pending timer, and an existing stopped
        // reason is never replaced with a user-interruption payload.
        if reason == .stoppedByUser { removeDebounceTask(for: identifier)?.cancel() }
        lock.withLock {
            if state.interventions[identifier] == .stoppedByUser, reason != .stoppedByUser { return }
            state.interventions[identifier] = reason
        }
    }
    func markStoppedByUser(for identifier: String) { setIntervention(.stoppedByUser, for: identifier) }
    func clearUserInterruptedIntervention(for identifier: String) {
        removeDebounceTask(for: identifier)?.cancel()
        lock.withLock {
            if case .userInterrupted = state.interventions[identifier] { state.interventions.removeValue(forKey: identifier) }
        }
    }
    func clearStoppedByUser(for identifier: String) {
        guard wasStoppedByUser(for: identifier) else { return }
        clearUserInterruptedIntervention(for: identifier)
        lock.withLock { _ = state.interventions.removeValue(forKey: identifier) }
    }
    func clearInterventionReason(for identifier: String) {
        clearUserInterruptedIntervention(for: identifier)
        lock.withLock { _ = state.interventions.removeValue(forKey: identifier) }
    }
    func clearUserInterruptedInterventionAfterStateRequery(for identifier: String) {
        guard let value = userInterruptedIntervention(for: identifier), value.requiresRequery,
              !value.isDebouncing(at: environment.now()) else { return }
        clearUserInterruptedIntervention(for: identifier)
    }
    func resolve(target: ComputerUseApplicationTarget, requestedIdentifier: String, create: Bool,
                 configuration: ControllerRequestConfiguration,
                 makeController: () throws -> Controller) throws -> Instance {
        // Check stopped before reading termination or constructing.
        let identifier = target.identifier
        if wasStoppedByUser(for: identifier) { throw ControllerInstanceResolutionError.stoppedByUser(requestedIdentifier) }
        if let existing = instance(for: identifier) {
            if !environment.isTerminated(existing.controller) { return existing }
            clearUserInterruptedIntervention(for: identifier)
            removeInstance(for: identifier)
        }
        guard create else { throw ControllerInstanceResolutionError.noInstance(requestedIdentifier) }
        let controller = try makeController()
        let created = Instance(target: target, configuration: configuration, controller: controller)
        setInstance(created)
        return created
    }
    func requireNotStopped(_ instance: Instance, requestedIdentifier: String) throws {
        if wasStoppedByUser(for: instance.applicationTarget.identifier) {
            throw ControllerInstanceResolutionError.stoppedByUser(requestedIdentifier)
        }
    }
    /// Marks the supplied string immediately, then deactivates and removes the
    /// instance on its own queue, after its preceding jobs.
    /// The stop reason survives removal; an unknown raw alias has no instance.
    func stop(_ identifier: String, deactivate: @escaping @Sendable (Controller) -> Void) async throws -> Instance? {
        markStoppedByUser(for: identifier)
        guard let instance = instance(for: identifier) else { return nil }
        try await instance.serialExecutor.execute { [self] in
            deactivate(instance.controller)
            clearUserInterruptedIntervention(for: instance.applicationTarget.identifier)
            removeInstance(for: instance.applicationTarget.identifier)
        }
        return instance
    }
    func registerUserInterruptedIntervention(for identifier: String) {
        let components = debounceDuration.components
        let interval = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let deadline = environment.now().addingTimeInterval(interval)
        // Starts an ordinary task, replaces/cancels the previous timer,
        // then publishes the reason. The deadline guards late timer callbacks.
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await environment.sleep(debounceDuration) } catch {}
            guard !Task.isCancelled else { return }
            if finishDebounce(for: identifier, deadline: deadline) { setCursorActivity(1, for: identifier) }
        }
        let previous = lock.withLock { state.debounceTasks.updateValue(task, forKey: identifier) }
        previous?.cancel()
        setIntervention(.userInterrupted(.init(requiresRequery: true, debounceDeadline: deadline)), for: identifier)
        setCursorActivity(2, for: identifier)
    }
    @discardableResult func finishDebounce(for identifier: String, deadline: Date) -> Bool {
        lock.withLock {
            guard case .userInterrupted(var value) = state.interventions[identifier], value.debounceDeadline == deadline else { return false }
            state.debounceTasks.removeValue(forKey: identifier)
            value.debounceDeadline = nil
            state.interventions[identifier] = .userInterrupted(value)
            return true
        }
    }
    private func setCursorActivity(_ activity: UInt8, for identifier: String) {
        guard let instance = instance(for: identifier) else { return }
        Task { @MainActor [environment] in environment.setCursorActivity(instance.controller, activity) }
    }
    /// Input outside a managed active controller creates no intervention.
    func receiveUserInput(for identifier: String) {
        guard let instance = lock.withLock({ state.instances.first {
            $0.applicationTarget.identifier == identifier && environment.isActive($0.controller)
        } }) else { return }
        registerUserInterruptedIntervention(for: identifier)
        Task { @MainActor [environment] in environment.postUserInterruption(instance.controller) }
    }
}
