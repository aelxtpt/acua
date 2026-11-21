import Foundation

@MainActor protocol ControllerLaunchPreparationBackend {
    associatedtype Target
    associatedtype Application
    associatedtype Node
    func running(_ target: Target) -> Application?
    func node(_ application: Application) -> Node
    func primaryWindow(_ application: Node) -> Node?
    func minimized(_ window: Node) -> Bool?
    func open(_ target: Target) async throws -> Application
    func now() -> Date
    func sleep(_ interval: Duration) async throws
    func settle(_ application: Node, delay: Double, notificationDelay: Double, scroll: Bool) async throws
}

/// Opening is skipped only for a running app with a non-minimized primary
/// window (an absent minimized flag also qualifies). Opening is outside the
/// eventual instance queue. Canonical instance resolution follows this method.
@MainActor struct ControllerLaunchPreparation<Backend: ControllerLaunchPreparationBackend> {
    let backend: Backend
    func prepare(_ target: Backend.Target) async throws {
        if let running = backend.running(target),
           let window = backend.primaryWindow(backend.node(running)), backend.minimized(window) != true { return }
        let opened = try await backend.open(target)
        let application = backend.node(opened)
        _ = try await primaryWindow(application, timeout: 5, pollingInterval: 0.05)
        try await backend.settle(application, delay: 0.05, notificationDelay: 0.25, scroll: false)
    }
    /// Uses Date for the timeout, ContinuousClock for sleeping,
    /// and reject only elapsed > timeout before each condition read. Sleep
    /// failures propagate; no cancellation check precedes a successful read.
    func primaryWindow(_ application: Backend.Node, timeout: Double, pollingInterval: Double) async throws -> Backend.Node {
        let started = backend.now()
        while true {
            if backend.now().timeIntervalSince(started) > timeout { throw SystemSettingsPollError.timeoutReached }
            if let window = backend.primaryWindow(application) { return window }
            try await backend.sleep(.seconds(pollingInterval))
        }
    }
}
