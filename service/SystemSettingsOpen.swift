import Foundation

struct SystemSettingsOpenEnvironment<Application: Sendable>: Sendable {
    typealias Completion = @Sendable (Application?, (any Error)?) -> Void
    let open: @Sendable (URL, Bool, @escaping Completion) -> Void
}
/// URL construction precedes opening; error takes priority,
/// nil application without error traps, and caller cancellation adds no cleanup.
struct SystemSettingsOpener<Application: Sendable>: Sendable {
    let environment: SystemSettingsOpenEnvironment<Application>
    func open(_ destination: SystemSettings.Destination, activate: Bool = true) async throws -> Application {
        let url = try SystemSettings.url(for: destination)
        return try await withUnsafeThrowingContinuation { continuation in
            environment.open(url, activate, Self.completion(continuation))
        }
    }
    // Explicitly nonisolated callback construction prevents a caller's actor
    // from being inferred for a completion delivered on a workspace queue.
    nonisolated private static func completion(_ continuation: UnsafeContinuation<Application, any Error>) -> SystemSettingsOpenEnvironment<Application>.Completion {
        { application, error in
            if let error { continuation.resume(throwing: error) }
            else {
                guard let application else { preconditionFailure("System Settings open returned no application and no error") }
                continuation.resume(returning: application)
            }
        }
    }
}
