import Foundation

protocol ControllerWindowOrderingLease: AnyObject, Sendable {}

/// Per-controller window ordering, with no global AppSessions gate.
final class ControllerWindowOrdering<Application: Sendable, Window: Sendable>: @unchecked Sendable {
    struct Event: Sendable, Equatable {
        let windowID: UInt32
        let ownerPID: Int32
    }
    struct Source: Sendable {
        let events: AsyncStream<Event>
        let lease: any ControllerWindowOrderingLease
    }
    enum Log: Sendable {
        case correctionStarted(Event, Window)
        case interruptedByWorkspace(Event, Window, Int)
        case raiseFailed(Window, any Error)
        case observationFailed(any Error)
    }
    struct Environment: Sendable {
        let events: @Sendable ([UInt32], Int) -> Source
        let frontmostApplication: @Sendable () -> Application?
        let processIdentifier: @Sendable (Application) -> Int32
        let resolvePID: @Sendable (Application) -> Int32
        let focusedWindow: @Sendable (Int32) -> Window?
        let windowID: @Sendable (Window) throws -> UInt32
        let windowOwner: @Sendable (UInt32) -> Int32?
        let onScreenWindowIDs: @Sendable () -> [UInt32]
        let observeWorkspaceAddition: @Sendable ([UInt32], @escaping @Sendable () -> Void) -> any ControllerWindowOrderingLease
        let raise: @Sendable (Window) throws -> Void
        let sleep: @Sendable (Duration) async throws -> Void
        let log: @Sendable (Log) -> Void
    }
    private struct State {
        var observedWindowIDs: [UInt32]
        var task: Task<Void, Never>?
        var menuTask: Task<Void, Never>?
    }
    private final class WeakOwner: @unchecked Sendable {
        // Swift weak storage supports concurrent load/release; no strong owner
        //is held while the event iterator is idle.
        weak var value: ControllerWindowOrdering?
        init(_ value: ControllerWindowOrdering) { self.value = value }
    }
    private final class AddedWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
    private let lock = NSLock()
    private var state: State
    let environment: Environment

    init(observedWindowIDs: [UInt32], environment: Environment) {
        state = .init(observedWindowIDs: observedWindowIDs)
        self.environment = environment
    }
    var observedWindowIDs: [UInt32] {
        get { lock.withLock { state.observedWindowIDs } }
        set { lock.withLock { state.observedWindowIDs = newValue } }
    }
    var hasObservationTask: Bool { lock.withLock { state.task != nil } }
    var hasMenuTask: Bool { lock.withLock { state.menuTask != nil } }
    func taskSnapshot() -> [Task<Void, Never>] { lock.withLock { [state.task, state.menuTask].compactMap { $0 } } }

    func start() {
        lock.withLock {
            guard state.task == nil else { return }
            let owner = WeakOwner(self), environment = environment
            state.task = Task(priority: .userInitiated) {
                await Self.observe(owner: owner, environment: environment)
            }
        }
    }
    func stop() {
        lock.withLock {
            state.task?.cancel(); state.task = nil
            state.menuTask?.cancel(); state.menuTask = nil
        }
    }
    deinit { stop() }

    private static func observe(owner: WeakOwner, environment: Environment) async {
        while !Task.isCancelled {
            guard let ids = owner.value?.observedWindowIDs else { return }
            let source = environment.events(ids, 1)
            await consume(source: source, ids: ids, owner: owner, environment: environment)
            withExtendedLifetime(source.lease) {}
        }
    }
    private static func consume(source: Source, ids: [UInt32], owner: WeakOwner, environment: Environment) async {
        for await event in source.events {
            guard let current = owner.value else { return }
            do { try await current.orderChanged(event) }
            catch is CancellationError {
                // The iterator is created again after a CancellationError even
                // when the enclosing task itself has not been cancelled.
                return
            } catch { environment.log(.observationFailed(error)) }
            if Set(ids) != Set(current.observedWindowIDs) { return }
        }
    }

    func orderChanged(_ event: Event) async throws {
        guard observedWindowIDs.contains(event.windowID), let application = environment.frontmostApplication(),
              environment.processIdentifier(application) != event.ownerPID else { return }
        let pid = environment.resolvePID(application)
        guard let window = environment.focusedWindow(pid) else { return }
        environment.log(.correctionStarted(event, window))
        let added = AddedWindow()
        let observation = environment.observeWorkspaceAddition(environment.onScreenWindowIDs(), { added.mark() })
        defer { withExtendedLifetime(observation) {} }
        for index in 0..<40 {
            if added.isSet {
                environment.log(.interruptedByWorkspace(event, window, index))
                return
            }
            do { try environment.raise(window) }
            catch { environment.log(.raiseFailed(window, error)) }
            // No extra active/focus/process/membership/deadline checks. Sleep
            // is the cooperative cancellation point.
            try await environment.sleep(.milliseconds(5))
        }
    }

    func menuDidOpen() {
        menuDidClose()
        let ids = observedWindowIDs
        let owners = Set(ids.compactMap(environment.windowOwner))
        guard !owners.isEmpty, let application = environment.frontmostApplication() else { return }
        let pid = environment.processIdentifier(application)
        guard !owners.contains(pid) else { return }
        lock.withLock {
            let environment = environment
            state.menuTask = Task(priority: .userInitiated) {
                await Self.correctMenu(foregroundPID: pid, observedIDs: ids, environment: environment)
            }
        }
    }
    func menuDidClose() {
        lock.withLock { state.menuTask?.cancel(); state.menuTask = nil }
    }
    static func correctMenu(foregroundPID: Int32, observedIDs: [UInt32], environment: Environment) async {
        guard let window = environment.focusedWindow(foregroundPID), let focusedID = try? environment.windowID(window) else { return }
        for _ in 0..<20 {
            do { try await environment.sleep(.milliseconds(5)) }
            catch { return }
            let ordered = environment.onScreenWindowIDs()
            if let focusedIndex = ordered.firstIndex(of: focusedID), observedIDs.contains(where: {
                guard let index = ordered.firstIndex(of: $0) else { return false }
                return index < focusedIndex
            }) {
                // Raise once and return, swallowing even raise errors.
                try? environment.raise(window)
                return
            }
        }
    }
}
