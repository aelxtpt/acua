import Foundation

/// Ready -> MainActor cancellation/readiness recheck -> restore.
/// A failed recheck takes the same fresh-value fallback as not-ready.
final class ControllerPasteAcknowledgementPoll<Instant: InstantProtocol, Snapshot: Sendable>: @unchecked Sendable where Instant.Duration == Duration {
    let observation: ControllerPasteObservationBox<Instant>
    private let now: @Sendable () -> Instant
    private let cancelled: @Sendable () -> Bool
    private let restore: @MainActor @Sendable () -> Bool
    private let readValues: (@Sendable () async throws -> Snapshot)?
    private let changed: @Sendable (Snapshot, Snapshot) -> Bool
    private let lock = NSLock()
    private var lastValues: Snapshot?
    init(observation: ControllerPasteObservationBox<Instant>, initialValues: Snapshot?,
         now: @escaping @Sendable () -> Instant, cancelled: @escaping @Sendable () -> Bool,
         restore: @escaping @MainActor @Sendable () -> Bool,
         readValues: (@Sendable () async throws -> Snapshot)?, changed: @escaping @Sendable (Snapshot, Snapshot) -> Bool) {
        self.observation = observation; self.lastValues = initialValues
        self.now = now; self.cancelled = cancelled; self.restore = restore
        self.readValues = initialValues == nil ? nil : readValues; self.changed = changed
    }
    func poll() async throws -> Bool? {
        if observation.isReady(now: now) { return try await restoreIfReady() }
        return try await sampleValues()
    }
    @MainActor private func restoreIfReady() async throws -> Bool? {
        if !cancelled(), observation.isReady(now: now) { return restore() }
        return try await sampleValues()
    }
    private func sampleValues() async throws -> Bool? {
        guard let readValues else { return nil }
        let fresh: Snapshot
        do { fresh = try await readValues() }
        catch { lock.withLock { lastValues = nil }; return nil }
        let time = now()
        let previous = lock.withLock { lastValues }
        let differs = previous.map { changed($0, fresh) } ?? false
        lock.withLock { lastValues = fresh }
        if differs { observation.withState { $0.edited(at: time) } }
        return nil
    }
}
