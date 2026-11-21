import Foundation

/// Synchronous connection workers wait without blocking MainActor. Only the
/// immutable permission result and telemetry snapshot cross this boundary.
struct ServicePermissionRequestBridge: Sendable {
    struct Environment: Sendable {
        let isMainThread: @Sendable () -> Bool
        let wait: @Sendable (DispatchSemaphore) throws -> Void
        let ensure: @MainActor @Sendable (ServicePermissionSource, String?) async -> ServicePermissionResult
    }
    private final class Pending: @unchecked Sendable {
        // PendingResult synchronizes every transfer. Permission values own no
        // native resources and the discard callback has no captured state.
        let value = PendingResult<ServicePermissionResult>(discard: { _ in })
    }
    let environment: Environment
    func check(source: ServicePermissionSource, appshotRequestID: String?) throws -> ServicePermissionResult {
        guard !environment.isMainThread() else {
            throw ServiceError(.permissionsPending, "Permission requests require a service worker")
        }
        let pending = Pending(), metadata = ComputerUseTelemetryContext.snapshot(), ensure = environment.ensure
        let task = Task { @MainActor in
            let result = await ComputerUseTelemetryContext.$current.withValue(metadata) {
                await ensure(source, appshotRequestID)
            }
            pending.value.complete(.success(result))
        }
        do {
            try environment.wait(pending.value.signal)
            return try pending.value.take()
        } catch {
            task.cancel(); pending.value.abandon(); throw error
        }
    }
}
