import Foundation

enum PermissionWindowStatus: UInt8, Sendable {
    case notDetermined, restricted, denied, authorized, unknown
}
enum PermissionWindowResult: UInt8, Sendable { case granted, denied, pending }
enum PermissionWindowRequestOutcome: UInt8, Sendable { case granted, denied, cancelled, failed }
// The window/catalog source is a DIFFERENT enum from the three IPC sources.
enum PermissionWindowSource: UInt8, Sendable {
    case appshot, calendar, computerUse, development, messages, timeline
}
typealias PermissionWindowCloseWaiter = @MainActor @Sendable () async -> Bool

@MainActor protocol PermissionWindowPresenting: AnyObject {
    var hasContent: Bool { get }
    var isVisible: Bool { get }
    func layoutAndFit()
    func center()
    func setLevel(_ level: Int)
    func closeWaiter() -> PermissionWindowCloseWaiter
    func activateApplication()
    func show()
    func makeKeyAndOrderFront()
    func close()
}
@MainActor protocol PermissionWindowHosting: AnyObject {
    /// Capture the current window and its content once. Native layout/status
    /// callbacks may replace the controller's window during a presentation.
    func currentWindow() -> (any PermissionWindowPresenting)?
}

/// The catalog/view, system-access coordinator and
/// status/request providers are composed separately; this owns their lifecycle.
@MainActor final class PermissionWindowCoordinator<Requirement: Hashable & Sendable> {
    struct Row: Sendable {
        let requirement: Requirement
        let isSupplemental: Bool
    }
    struct State: Equatable, Sendable {
        var requested = Set<Requirement>()
        var activeRequest: Requirement?
        var transitioningRequirement: Requirement?
        var statuses = [Requirement: PermissionWindowStatus]()
    }
    struct PresentationCompletion: Sendable {
        let result: PermissionWindowResult
        let dismissalIsAbandonment: Bool
        let requested: Set<Requirement>
        let source: PermissionWindowSource
    }
    struct PresentationStart: Sendable {
        let wasVisible: Bool
        let source: PermissionWindowSource
    }
    struct Environment {
        let status: @MainActor @Sendable (Requirement) -> PermissionWindowStatus
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var changed: @MainActor @Sendable (State) -> Void = { _ in }
        var requestFinished: @MainActor @Sendable (Requirement, PermissionWindowRequestOutcome) -> Void = { _, _ in }
        var closed: @MainActor @Sendable () -> Void = {}
        var presentationStarted: @MainActor @Sendable (PresentationStart) -> Void = { _ in }
        var presentationFinished: @MainActor @Sendable (PresentationCompletion) -> Void = { _ in }
        var makeObservationID: @MainActor @Sendable () -> UUID = { UUID() }
    }
    private struct Observation {
        let id: UUID
        let allowsSettingsTermination: Bool
        let cancel: @MainActor @Sendable () -> Void
    }
    let rows: [Row]
    let window: any PermissionWindowHosting
    let environment: Environment
    let pendingTimeout: Duration
    let catalogSource: PermissionWindowSource
    private(set) var state = State()
    private var observations = [Requirement: Observation]()
    private var permissionRequestTask: Task<Void, Never>?
    var observationCount: Int { observations.count }
    var hasRequestTask: Bool { permissionRequestTask != nil }

    init(rows: [Row], window: any PermissionWindowHosting, pendingTimeout: Duration,
         catalogSource: PermissionWindowSource = .computerUse,
         environment: Environment) {
        self.rows = rows; self.window = window; self.pendingTimeout = pendingTimeout
        self.environment = environment; self.catalogSource = catalogSource
    }
    private func allAuthorized(_ requirements: Set<Requirement>) -> Bool {
        requirements.allSatisfy { environment.status($0) == .authorized }
    }
    var hasMissingRequestedPermission: Bool { !allAuthorized(state.requested) }
    var hasMissingSupplementalPermission: Bool {
        !allAuthorized(Set(rows.filter(\.isSupplemental).map(\.requirement)))
    }
    // A visible window with no observation also prevents termination.
    var shouldPreventSystemSettingsTermination: Bool {
        window.currentWindow()?.isVisible == true && !observations.values.contains { $0.allowsSettingsTermination }
    }
    func refresh() {
        for row in rows {
            let current = environment.status(row.requirement)
            if current == .unknown && state.statuses[row.requirement] != nil { continue }
            state.statuses[row.requirement] = current
            environment.changed(state)
        }
        // Closing is not guarded by window visibility.
        if !state.requested.isEmpty && !hasMissingRequestedPermission && !hasMissingSupplementalPermission {
            cancelObservations()
            window.currentWindow()?.close()
        }
    }
    func present(requirements: Set<Requirement>, source: PermissionWindowSource? = nil,
                 treatDismissalAsAbandonment: Bool) async -> PermissionWindowResult {
        // The fast path precedes state/window/telemetry changes, including an empty set.
        if allAuthorized(requirements) { return .granted }
        let requestedChanged = state.requested != requirements
        state.requested = requirements
        if requestedChanged { environment.changed(state) }
        guard let presentation = window.currentWindow(), presentation.hasContent else { return .pending }
        let wasVisible = presentation.isVisible
        presentation.layoutAndFit(); presentation.center(); presentation.setLevel(3)
        let close = presentation.closeWaiter()
        presentation.activateApplication(); presentation.show(); presentation.makeKeyAndOrderFront()
        let source = source ?? catalogSource
        environment.presentationStarted(.init(wasVisible: wasVisible, source: source))
        refresh()
        let status = environment.status, sleep = environment.sleep, timeout = pendingTimeout
        let afterClose: @MainActor @Sendable () async -> PermissionWindowResult = {
            guard await close() else { return .denied }
            return requirements.allSatisfy { status($0) == .authorized } ? .granted : .denied
        }
        let result = await withTaskGroup(of: PermissionWindowResult.self) { group in
            group.addTask { await afterClose() }
            group.addTask {
                // Sleep error/cancellation returns the same pending value.
                try? await sleep(timeout)
                return .pending
            }
            let first = await group.next() ?? .denied
            group.cancelAll()
            return first
        }
        // Abandonment changes the analytics outcome, not the returned three-case enum.
        environment.presentationFinished(.init(result: result,
            dismissalIsAbandonment: result == .denied && treatDismissalAsAbandonment, requested: requirements, source: source))
        return result
    }
    // One active request, retained across suspension.
    @discardableResult func request(_ requirement: Requirement,
        operation: @escaping @MainActor @Sendable () async -> PermissionWindowRequestOutcome) -> Bool {
        guard state.activeRequest == nil else { return false }
        state.activeRequest = requirement; environment.changed(state)
        refresh()
        permissionRequestTask = Task { @MainActor in
            let outcome = await operation()
            finishRequest(requirement, outcome: outcome)
            // Clear the stored task even when the active identity changed.
            permissionRequestTask = nil
        }
        return true
    }
    private func finishRequest(_ requirement: Requirement, outcome: PermissionWindowRequestOutcome) {
        guard state.activeRequest == requirement else { return }
        // Callback observes the still-active requirement. It cannot start a second request.
        environment.requestFinished(requirement, outcome)
        state.activeRequest = nil; environment.changed(state)
        if outcome == .denied {
            state.statuses[requirement] = .denied; environment.changed(state)
        }
        refresh()
        raiseIfNeeded()
    }
    // A replacement cancels first; stale completion IDs are ignored.
    @discardableResult func beginObservation(for requirement: Requirement, allowsSettingsTermination: Bool,
        cancel: @escaping @MainActor @Sendable () -> Void) -> UUID {
        beginObservation(for: requirement, allowsSettingsTermination: allowsSettingsTermination, makeCancellation: { _ in cancel })
    }
    /// Creates the activation sequence/task after cancelling the old task
    /// and before publishing its replacement observation entry.
    @discardableResult func beginObservation(for requirement: Requirement, allowsSettingsTermination: Bool,
        makeCancellation: @MainActor (UUID) -> (@MainActor @Sendable () -> Void)) -> UUID {
        observations[requirement]?.cancel()
        let id = environment.makeObservationID()
        let cancel = makeCancellation(id)
        observations[requirement] = .init(id: id, allowsSettingsTermination: allowsSettingsTermination, cancel: cancel)
        return id
    }
    func finishObservation(for requirement: Requirement, id: UUID) {
        guard observations[requirement]?.id == id else { return }
        observations[requirement] = nil
        raiseIfNeeded()
    }
    func cancelObservations() {
        for observation in observations.values { observation.cancel() }
        observations.removeAll()
    }
    func raiseIfNeeded() {
        guard let presentation = window.currentWindow(), presentation.isVisible,
              hasMissingRequestedPermission || hasMissingSupplementalPermission,
              observations.isEmpty else { return }
        presentation.setLevel(3); presentation.activateApplication(); presentation.makeKeyAndOrderFront()
    }
    func windowWillClose() {
        // Keep the request task until its asynchronous completion.
        permissionRequestTask?.cancel()
        cancelObservations()
        environment.closed()
    }
    func accessoryTransitionStarted(for requirement: Requirement) {
        guard state.activeRequest == requirement, state.transitioningRequirement != requirement else { return }
        state.transitioningRequirement=requirement;environment.changed(state)
    }
    func accessoryTransitionCompleted(for requirement: Requirement) {
        guard state.transitioningRequirement == requirement else { return }
        state.transitioningRequirement=nil;environment.changed(state)
    }
}
