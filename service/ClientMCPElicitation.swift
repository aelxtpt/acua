import Foundation
import MCP

enum AcuaMCPElicitationError: Error, Equatable, CustomStringConvertible {
    case notDeclaredByClient

    var description: String {
        switch self {
        case .notDeclaredByClient:
            "This action needs the user's approval through MCP elicitation, which this MCP client did not declare at initialize."
        }
    }
}

/// Approval requests from the helper to its MCP client.
enum AcuaMCPElicitation {
    /// The MCP spec forbids sending elicitation to a client that did not
    /// declare it, and the SDK (in its default, non-strict mode) would send
    /// it anyway and wait for an answer that never comes.
    static func request(clientSupportsElicitation: Bool = CUAMCPInvocationContext.clientSupportsElicitation,
                        _ elicit: @escaping @Sendable () async throws -> CreateElicitation.Result) async throws -> CreateElicitation.Result {
        guard clientSupportsElicitation else {
            throw AcuaMCPElicitationError.notDeclaredByClient
        }

        return try await untilCancelled(elicit)
    }

    /// Runs `operation`, but returns CancellationError as soon as the calling
    /// task is cancelled. The SDK's wait for an elicitation answer ignores
    /// cancellation, so without this a tool call the client cancelled would
    /// stay open until the user answered the form, and then act on it.
    /// A result that arrives after the cancellation is dropped.
    static func untilCancelled<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome = AcuaFirstOutcome<T>()
        let running = Task { outcome.finish(await Result(catching: operation)) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.attach(continuation)
            }
        } onCancel: {
            running.cancel()
            outcome.finish(.failure(CancellationError()))
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

/// Resumes one continuation with whichever outcome comes first: the
/// operation's result or the cancellation. Either may come before the
/// continuation exists, and the later one is dropped.
private final class AcuaFirstOutcome<T: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting
        case attached(CheckedContinuation<T, Error>)
        case finished(Result<T, Error>)
        case delivered
    }

    private let lock = NSLock()
    private var state = State.waiting

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        guard case .finished(let outcome) = state else {
            state = .attached(continuation)
            lock.unlock()
            return
        }

        state = .delivered
        lock.unlock()
        continuation.resume(with: outcome)
    }

    func finish(_ outcome: Result<T, Error>) {
        lock.lock()
        switch state {
        case .waiting:
            state = .finished(outcome)
            lock.unlock()
        case .attached(let continuation):
            state = .delivered
            lock.unlock()
            continuation.resume(with: outcome)
        case .finished, .delivered:
            lock.unlock()
        }
    }
}
