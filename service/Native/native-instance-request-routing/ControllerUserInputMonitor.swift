import Foundation

struct ControllerUserInputEvent: Sendable, Equatable {
    let sourcePID: Int32
    let targetPID: Int32
    let windowID: UInt32?
}

struct ControllerUserInputObservation: Sendable {
    let read: @Sendable () -> ControllerUserInputEvent?
    init(read: @escaping @Sendable () -> ControllerUserInputEvent?) { self.read = read }
    init(sourcePID: Int32, targetPID: Int32, windowID: UInt32?) {
        let event = ControllerUserInputEvent(sourcePID: sourcePID, targetPID: targetPID, windowID: windowID)
        read = { event }
    }
}

/// One ordinary task consumes events while any controller
/// is active. The producer owns its tap; cancellation ends its AsyncStream.
final class ControllerUserInputMonitor: @unchecked Sendable {
    struct Environment: Sendable {
        let ignoredSourcePID: Int32
        let events: @Sendable () -> AsyncStream<ControllerUserInputObservation>
        let resolveTarget: @Sendable (ControllerUserInputEvent) async -> String?
    }
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var handler: (@Sendable (String) -> Void)?
    let environment: Environment
    init(environment: Environment) { self.environment = environment }
    func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        let previous = lock.withLock { let previous = self.handler; self.handler = handler; return previous }
        withExtendedLifetime(previous) {}
    }
    func updateActiveCount(_ count: Int) {
        let previous = lock.withLock {
            if count < 1 {
                let previous = task; task = nil; return previous
            }
            if task == nil {
                task = Task { [weak self] in
                    guard let self else { return }
                    await run()
                }
            }
            return nil as Task<Void, Never>?
        }
        previous?.cancel()
    }
    private func run() async {
        for await observation in environment.events() {
            guard !Task.isCancelled else { return }
            // Check cancellation before obtaining the CGEvent and its fields.
            guard let event = observation.read() else { continue }
            guard event.sourcePID != environment.ignoredSourcePID else { continue }
            if let target = await environment.resolveTarget(event) {
                // Resolve first, then read the current callback;
                // there is no second cancellation check after that await.
                let callback = lock.withLock { handler }
                callback?(target)
            }
        }
    }
}

struct ControllerUserInputTargetResolver<Application: Sendable>: Sendable {
    let windowOwner: @Sendable (UInt32) -> Int32?
    let application: @Sendable (Int32) -> Application?
    let bundleURL: @Sendable (Application) -> URL?
    let bundleIdentifier: @Sendable (Application) -> String?

    func resolve(_ event: ControllerUserInputEvent) -> String? {
        // Use the window owner when a window was found, even if that
        // owner's application cannot be resolved. Only an absent window falls
        // back to eventTargetUnixProcessID.
        let pid = event.windowID.flatMap(windowOwner) ?? event.targetPID
        guard let app = application(pid) else { return nil }
        // Prefer the canonical path, but keep a bundle-ID fallback
        // when NSRunningApplication supplies no bundle URL.
        return bundleURL(app).map(ComputerUseApplicationTarget.identifier(for:)) ?? bundleIdentifier(app)
    }
}
