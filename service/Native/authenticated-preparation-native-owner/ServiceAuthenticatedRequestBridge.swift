import Foundation

/// Only immutable request flags and the complete telemetry value cross to the
/// delegate actor. The connection keeps its untyped body and decoding executor.
struct ServiceAuthenticatedRequestBridge: Sendable {
    struct Environment: Sendable {
        let isMainThread: @Sendable () -> Bool
        let wait: @Sendable (DispatchSemaphore) throws -> Void
        let prepare: @MainActor @Sendable (Bool, Bool) async throws -> Void
    }
    private final class Pending: @unchecked Sendable {
        // Locked once-only transfer; Void carries no native resources or lease.
        let value = PendingResult<Void>(discard: { _ in })
    }
    let environment: Environment
    func prepare(preparesTurn: Bool, allowsAutoUnlock: Bool) throws {
        guard !environment.isMainThread() else {
            throw ServiceError(.unknownError, "Authenticated requests require a service worker")
        }
        let pending = Pending(), metadata = ComputerUseTelemetryContext.snapshot(), prepare = environment.prepare
        let task = Task { @MainActor in
            do {
                try await ComputerUseTelemetryContext.$current.withValue(metadata) {
                    try await prepare(preparesTurn, allowsAutoUnlock)
                }
                pending.value.complete(.success(()))
            } catch { pending.value.complete(.failure(error)) }
        }
        do {
            try environment.wait(pending.value.signal)
            try pending.value.take()
        } catch {
            task.cancel(); pending.value.abandon(); throw error
        }
        // A request returning or expiring never ends a thread's unlock lease.
    }
}
