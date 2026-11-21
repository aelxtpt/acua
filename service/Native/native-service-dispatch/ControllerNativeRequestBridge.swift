import Foundation

private final class ControllerNativeBridgeWaiter<Value: Sendable>: @unchecked Sendable {
    //PendingResult's transitions and result ownership are protected by its lock.
    let value = PendingResult<Value>(discard:{_ in})
}
enum ControllerNativeRequestBridge {
    static func wait<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) throws -> Value {
        guard !Thread.isMainThread else {throw ServiceError(.unknownError,"Native application requests require a connection worker")}
        let pending=ControllerNativeBridgeWaiter<Value>(),metadata=ComputerUseTelemetryContext.snapshot(),scope=RequestRuntime.asynchronousScope()
        let task=Task { @MainActor in
            do {
                let value=try await RequestRuntime.withAsyncScope(scope) {
                    try await ComputerUseTelemetryContext.$current.withValue(metadata) {try await operation()}
                }
                pending.value.complete(.success(value))
            } catch {pending.value.complete(.failure(error))}
        }
        defer {task.cancel();pending.value.abandon()}
        try RequestRuntime.wait(for:pending.value.signal,maximumSeconds:120)
        return try pending.value.take()
    }
}
