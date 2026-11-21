import Foundation

/// Transfers an asynchronous result exactly once, including the race where a
/// request expires just as its callback completes. Unclaimed resources are
/// disposed outside the lock.
final class PendingResult<Value> {
    private enum State { case pending, completed(Result<Value, Error>), consumed, abandoned }
    private var state: State = .pending
    private let lock = NSLock()
    private let discard: (Value) -> Void
    let signal = DispatchSemaphore(value: 0)
    init(discard: @escaping (Value) -> Void) { self.discard = discard }

    func complete(_ outcome: Result<Value, Error>) {
        lock.lock()
        if case .pending = state {
            state = .completed(outcome); lock.unlock(); signal.signal()
        } else {
            lock.unlock()
            if case .success(let value) = outcome { discard(value) }
        }
    }
    func abandon() {
        lock.lock()
        let outcome: Result<Value, Error>?
        switch state {
        case .completed(let value): outcome = value; state = .abandoned
        case .pending: outcome = nil; state = .abandoned
        default: outcome = nil
        }
        lock.unlock()
        if case .success(let value) = outcome { discard(value) }
    }
    func take() throws -> Value {
        lock.lock()
        guard case .completed(let outcome) = state else {
            lock.unlock(); throw ServiceError(.unknownError, "Asynchronous result is unavailable")
        }
        state = .consumed; lock.unlock()
        return try outcome.get()
    }
}
