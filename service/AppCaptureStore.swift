import Foundation

/// FIFO capture stages with a single pending reader.
/// Generations prevent a replaced producer from publishing into a reused ID.
/// A delivery is committed after successful transport; abandoning it preserves the stage.
final class AppCaptureStore<Value> {
    enum Retirement { case consumed, cancelled }
    enum StoreError: Error, Equatable { case missing, replaced, readerBusy, readerSuperseded, full, finished, timedOut }
    struct Token: Equatable { let requestID: String; fileprivate let generation = UUID() }
    private struct Stage { let value: Value; let terminal: Bool }
    private struct Reader {
        let id: UUID
        var reserved: Bool
    }
    private final class Entry {
        let token: Token
        var expiresAt: ContinuousClock.Instant?
        var expiryTask: Task<Void, Never>?
        let cancel: (Retirement) -> Void
        var stages: [Stage] = []
        var reader: Reader?
        var finished = false
        init(token: Token, expiresAt: ContinuousClock.Instant?, cancel: @escaping (Retirement) -> Void) {
            self.token = token; self.expiresAt = expiresAt; self.cancel = cancel
        }
    }
    final class Delivery {
        let value: Value
        private weak var store: AppCaptureStore?
        private let token: Token
        private let reader: UUID
        fileprivate init(value: Value, store: AppCaptureStore, token: Token, reader: UUID) {
            self.value = value; self.store = store; self.token = token; self.reader = reader
        }
        func commit(check: () throws -> Void = {}) throws {
            try check()
            guard let store else { throw StoreError.missing }
            try store.commit(token, reader: reader)
        }
        func abandon() { store?.abandon(token, reader: reader) }
        deinit { abandon() }
    }
    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]
    private let maximumCaptures, maximumStages: Int?
    private let lifetime: Duration?
    private let terminalRetention: Duration
    private let now: () -> ContinuousClock.Instant
    private let discard: (Value) -> Void

    /// An unread terminal stage is retained for 30 seconds by default.
    /// The request dictionary and update array grow without fixed cutoffs. Capacity bounds are explicit opt-in limits;
    /// an optional active lifetime is also disabled by default.
    /// AppCaptureCoordinator owns production workers and delivery publication.
    init(maximumCaptures: Int? = nil, maximumStages: Int? = nil, lifetime: TimeInterval? = nil,
         terminalRetention: TimeInterval = 30,
         now: @escaping () -> ContinuousClock.Instant = { .now },
         discard: @escaping (Value) -> Void = { _ in }) {
        precondition(maximumCaptures.map { $0 > 0 } ?? true)
        precondition(maximumStages.map { $0 > 0 } ?? true)
        precondition(lifetime == nil || lifetime!.isFinite && lifetime! > 0)
        precondition(terminalRetention.isFinite && terminalRetention > 0)
        self.maximumCaptures = maximumCaptures; self.maximumStages = maximumStages
        self.lifetime = lifetime.map { .seconds($0) }
        self.terminalRetention = .seconds(terminalRetention); self.now = now; self.discard = discard
    }
    deinit { removeAll() }

    func begin(requestID: String, cancel: @escaping () -> Void) throws -> Token {
        try begin(requestID: requestID, onRetire: { _ in cancel() })
    }
    func begin(requestID: String, onRetire: @escaping (Retirement) -> Void) throws -> Token {
        reapExpired()
        let token = Token(requestID: requestID), expiresAt = lifetime.map { now().advanced(by: $0) }
        condition.lock()
        guard entries[requestID] != nil || (maximumCaptures.map { entries.count < $0 } ?? true) else {
            condition.unlock(); throw StoreError.full
        }
        let old = entries.updateValue(Entry(token: token, expiresAt: expiresAt, cancel: onRetire), forKey: requestID)
        condition.broadcast(); condition.unlock()
        if let old { retire(old) }
        if let expiresAt { scheduleExpiry(token, at: expiresAt) }
        return token
    }

    /// On failure the store discards the supplied value exactly once.
    func publish(_ value: Value, token: Token, terminal: Bool = false) throws {
        reapExpired()
        let instant = now()
        condition.lock()
        let failure: StoreError?
        var terminalDeadline: ContinuousClock.Instant?
        if let entry = entries[token.requestID] {
            if entry.token != token { failure = .replaced }
            else if entry.finished { failure = .finished }
            else if let maximumStages, entry.stages.count >= maximumStages { failure = .full }
            else {
                entry.stages.append(Stage(value: value, terminal: terminal))
                entry.reader?.reserved = true
                entry.finished = terminal; failure = nil
                if terminal {
                    let terminalExpiry = instant.advanced(by: terminalRetention)
                    let expires = min(entry.expiresAt ?? terminalExpiry, terminalExpiry)
                    entry.expiresAt = expires; terminalDeadline = expires
                }
            }
        } else { failure = .missing }
        condition.broadcast(); condition.unlock()
        if let failure { discard(value); throw failure }
        if let terminalDeadline { scheduleExpiry(token, at: terminalDeadline) }
    }

    /// The checkpoint executes outside the store lock, and runs while waiting.
    /// Callers retain the delivery through encoding, then commit or abandon it.
    func next(requestID: String, maximumWait: TimeInterval = 120,
              check: () throws -> Void) throws -> Delivery {
        guard maximumWait.isFinite, maximumWait >= 0 else { throw StoreError.timedOut }
        try check(); reapExpired()
        let limit = ProcessInfo.processInfo.systemUptime + maximumWait
        let reader = UUID()
        condition.lock()
        guard let entry = entries[requestID] else { condition.unlock(); throw StoreError.missing }
        guard entry.reader?.reserved != true else { condition.unlock(); throw StoreError.readerBusy }
        // A new reader replaces the pending continuation when no update is
        // queued. Wake the superseded reader so it can finish with an error.
        if entry.reader != nil { condition.broadcast() }
        entry.reader = Reader(id: reader, reserved: !entry.stages.isEmpty)
        condition.unlock()
        var delivered = false
        defer { if !delivered { abandon(entry.token, reader: reader) } }
        while true {
            try check(); reapExpired()
            condition.lock()
            guard entries[requestID] === entry else { condition.unlock(); throw StoreError.replaced }
            guard entry.reader?.id == reader else { condition.unlock(); throw StoreError.readerSuperseded }
            if let first = entry.stages.first {
                condition.unlock(); delivered = true
                return Delivery(value: first.value, store: self, token: entry.token, reader: reader)
            }
            guard ProcessInfo.processInfo.systemUptime < limit else { condition.unlock(); throw StoreError.timedOut }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            condition.unlock()
        }
    }

    private func commit(_ token: Token, reader: UUID) throws {
        reapExpired()
        condition.lock()
        guard let entry = entries[token.requestID], entry.token == token else { condition.unlock(); throw StoreError.replaced }
        guard entry.reader?.id == reader, let first = entry.stages.first else { condition.unlock(); throw StoreError.readerBusy }
        entry.stages.removeFirst(); entry.reader = nil
        if first.terminal { entries.removeValue(forKey: token.requestID) }
        condition.broadcast(); condition.unlock()
        if first.terminal { retire(entry, reason: .consumed) }
    }
    private func abandon(_ token: Token, reader: UUID) {
        condition.lock()
        if let entry = entries[token.requestID], entry.token == token, entry.reader?.id == reader {
            entry.reader = nil; condition.broadcast()
        }
        condition.unlock()
    }
    func remove(_ token: Token) {
        remove(token, expiringAt: nil)
    }
    private func remove(_ token: Token, expiringAt deadline: ContinuousClock.Instant?) {
        condition.lock()
        guard let entry = entries[token.requestID], entry.token == token,
              deadline == nil || entry.expiresAt == deadline else { condition.unlock(); return }
        entries.removeValue(forKey: token.requestID)
        condition.broadcast()
        condition.unlock()
        retire(entry)
    }
    func removeAll() {
        condition.lock(); let old = Array(entries.values); entries.removeAll(); condition.broadcast(); condition.unlock()
        for entry in old { retire(entry) }
    }
    func reapExpired() {
        let instant = now()
        condition.lock()
        let old = entries.values.filter { $0.expiresAt.map { $0 <= instant } ?? false }
        for entry in old { entries.removeValue(forKey: entry.token.requestID) }
        if !old.isEmpty { condition.broadcast() }
        condition.unlock()
        for entry in old { retire(entry) }
    }
    private func retire(_ entry: Entry, reason: Retirement = .cancelled) {
        // The detached entry has no writer; never call producer/resource cleanup
        // under the condition lock because cleanup can reenter the store.
        entry.expiryTask?.cancel()
        entry.cancel(reason)
        for stage in entry.stages { discard(stage.value) }
    }
    private func scheduleExpiry(_ token: Token, at deadline: ContinuousClock.Instant) {
        let task = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.remove(token, expiringAt: deadline)
        }
        condition.lock()
        let old: Task<Void, Never>?
        if let entry = entries[token.requestID], entry.token == token, entry.expiresAt == deadline {
            old = entry.expiryTask; entry.expiryTask = task
        } else { old = task }
        condition.unlock()
        old?.cancel()
    }
    var count: Int { condition.lock(); defer { condition.unlock() }; return entries.count }
}
