import Foundation

enum ControllerPastePollingFailure: Error, Equatable { case timedOut }

enum ControllerPasteWaiting {
    private enum TimeoutEvent<Value: Sendable>: Sendable { case value(Value), timeout }

    /// A timeout cancels the group but still consumes its operation's
    /// event. AsyncStream.next then returns nil; an operation's error is retained.
    static func firstRead<Value: Sendable>(timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of:TimeoutEvent<Value>.self) { group in
            defer { group.cancelAll() }
            group.addTask { .value(try await operation()) }
            group.addTask { try await ContinuousClock().sleep(for:timeout); return .timeout }
            while let event = try await group.next() {
                switch event {
                case .value(let value): return value
                case .timeout: group.cancelAll()
                }
            }
            throw CancellationError()
        }
    }

    /// Uses Date for the overall deadline and ContinuousClock for
    /// each delay. Equality at the deadline still runs the condition.
    static func poll<Value: Sendable>(timeout: Double, delay: Double,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for:$0) },
        condition: @escaping @Sendable () async throws -> Value?) async throws -> Value {
        let start = now()
        while now().timeIntervalSince(start) <= timeout {
            if let value = try await condition() { return value }
            try await sleep(.seconds(delay))
        }
        throw ControllerPastePollingFailure.timedOut
    }
}

///One queue for paste across every controller, not a new queue per operation.
enum ControllerGlobalPasteQueue {
    static let shared = AsyncSerialQueue()
}
