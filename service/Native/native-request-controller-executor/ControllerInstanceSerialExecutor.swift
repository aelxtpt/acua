import Foundation

private enum ControllerInstanceTask {
    nonisolated static func start<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
        return Task(operation: operation)
    }
    nonisolated static func completion<Value: Sendable>(_ task: Task<Value, Error>) -> Task<Void, Never> {
        // The tail awaits the result, not the value: a failed operation does
        // not poison subsequent requests. It is not cleared just because it ended.
        Task { _ = await task.result }
    }
}

/// A task chain serializes whole asynchronous operations;
/// actor isolation alone would permit another job during an await.
actor ControllerInstanceSerialExecutor {
    private var tail: Task<Void, Never>?
    func execute<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let previous = tail
        let task = ControllerInstanceTask.start {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            return try await operation()
        }
        tail = ControllerInstanceTask.completion(task)
        // This is an unstructured job. Cancelling the waiter does not
        // implicitly cancel this task or skip an already queued operation.
        return try await task.value
    }
}
