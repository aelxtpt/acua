import Foundation

// Serial queue: one consumer, unbounded buffering, awaited jobs. The worker
// captures the stream rather than the queue so destruction can cancel it.
final class AsyncSerialQueue: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void
    private let continuation: AsyncStream<Operation>.Continuation
    private let task: Task<Void, Never>

    init() {
        let pair = AsyncStream<Operation>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        let stream = pair.stream
        task = Task {
            for await operation in stream { await operation() }
        }
    }

    func async(_ operation: @escaping Operation) { continuation.yield(operation) }
    func sync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if #available(macOS 26.0, *) {
            let worker = task
            worker.escalatePriority(to: Task.currentPriority)
            return try await _isolatedParameter_withTaskPriorityEscalationHandler(operation: {
                try await self.enqueueSync(operation)
            }, onPriorityEscalated: { _, newPriority in
                worker.escalatePriority(to: newPriority)
            }, isolation: nil)
        }
        return try await enqueueSync(operation)
    }

    private func enqueueSync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { result in
            switch continuation.yield({
                do { result.resume(returning: try await operation()) }
                catch { result.resume(throwing: error) }
            }) {
            case .enqueued: break
            case .dropped, .terminated: result.resume(throwing: CancellationError())
            @unknown default: result.resume(throwing: CancellationError())
            }
        }
    }

    deinit { continuation.finish(); task.cancel() }
}
