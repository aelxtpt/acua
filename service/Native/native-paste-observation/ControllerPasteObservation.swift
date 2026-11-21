import Foundation

struct ControllerPasteObservation<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    struct Read: Sendable {
        let start: Instant
        var end: Instant?
        var succeeded = false
        var pendingEdit: Instant?
    }
    var dispatchAt: Instant?
    private(set) var reads: [Read] = []
    private(set) var activeReadCount = 0
    private(set) var lastReadFinishedAt: Instant?
    private(set) var quietDeadline: Instant?

    mutating func readStarted(at start: Instant) {
        activeReadCount += 1
        reads.append(.init(start: start))
        if reads.count > 128 { reads.removeFirst() }
    }
    mutating func readFinished(start: Instant, end: Instant, succeeded: Bool) {
        activeReadCount -= 1
        lastReadFinishedAt = max(lastReadFinishedAt ?? end, end)
        if let previous = quietDeadline { quietDeadline = max(previous, end.advanced(by: .milliseconds(100))) }
        guard let index = reads.firstIndex(where: { $0.start == start }) else { return }
        reads[index].end = end
        reads[index].succeeded = succeeded
        if succeeded, let edit = reads[index].pendingEdit, end.duration(to: edit) <= .milliseconds(50) {
            recordQuietEdit(at: edit)
        }
    }
    mutating func edited(at time: Instant) {
        guard let dispatchAt else { return }
        var candidate: Int?
        for index in reads.indices where reads[index].start >= dispatchAt && reads[index].start <= time {
            if let previous = candidate {
                if reads[previous].start < reads[index].start { candidate = index }
            } else { candidate = index }
        }
        guard let index = candidate else { return }
        if let end = reads[index].end {
            if reads[index].succeeded, end.duration(to: time) <= .milliseconds(50) { recordQuietEdit(at: time) }
        } else {
            reads[index].pendingEdit = max(reads[index].pendingEdit ?? time, time)
        }
    }
    private mutating func recordQuietEdit(at time: Instant) {
        let deadline = max(lastReadFinishedAt ?? time, time).advanced(by: .milliseconds(100))
        quietDeadline = max(quietDeadline ?? deadline, deadline)
    }
    func isReady(at time: Instant) -> Bool {
        guard let quietDeadline, activeReadCount == 0 else { return false }
        return time >= quietDeadline
    }
}

final class ControllerPasteObservationBox<Instant: InstantProtocol>: @unchecked Sendable where Instant.Duration == Duration {
    typealias State = ControllerPasteObservation<Instant>
    private let lock = NSLock()
    private var stored = State()
    func withState<Value>(_ body: (inout State) throws -> Value) rethrows -> Value {
        try lock.withLock { try body(&stored) }
    }
    var snapshot: State { lock.withLock { stored } }
    /// Samples the clock inside the observation lock.
    func isReady(now: () -> Instant) -> Bool { lock.withLock { stored.isReady(at: now()) } }
}
