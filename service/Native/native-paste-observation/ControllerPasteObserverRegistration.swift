import Foundation

final class ControllerPasteObserverRegistration<Handle: Sendable>: @unchecked Sendable {
    struct Environment: Sendable {
        let create: @Sendable (@escaping @Sendable () -> Void) throws -> Handle
        let register: @Sendable (Handle, String) throws -> Void
        let start: @Sendable (Handle, QualityOfService) -> Void
        let stop: @Sendable (Handle) -> Void
        let logRegistrationError: @Sendable (String, Error) -> Void
    }
    static var names: [String] { ["AXSelectedTextChanged", "AXValueChanged"] }
    let handle: Handle
    private let environment: Environment
    private let lock = NSLock()
    private var stopped = false
    private init(handle: Handle, environment: Environment) { self.handle = handle; self.environment = environment }
    static func make(environment: Environment, edited: @escaping @Sendable () -> Void) -> ControllerPasteObserverRegistration? {
        let handle: Handle
        do { handle = try environment.create(edited) } catch { return nil }
        let value = ControllerPasteObserverRegistration(handle: handle, environment: environment)
        for name in names {
            do { try environment.register(handle, name) }
            catch { environment.logRegistrationError(name, error) }
        }
        environment.start(handle, .userInitiated)
        return value
    }
    func stop() {
        let shouldStop = lock.withLock { if stopped { return false }; stopped = true; return true }
        if shouldStop { environment.stop(handle) }
    }
    deinit { stop() }
}
