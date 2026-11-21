import Foundation

@MainActor
protocol EventStreamRecordWriting: AnyObject {
    func append(_ record: EventStreamRecord) throws
}

extension EventStreamJSONLWriter: EventStreamRecordWriting {}

// EventStreamService's receive/process/commit paths. This component
// neither starts native recording nor publishes IPC success on its own.
@MainActor
final class EventStreamRecordProcessor {
    private struct Pending {
        let record: EventStreamRecord
        let isSuppressed: Bool
    }
    var writer: EventStreamRecordWriting?
    private let filter: EventStreamRecordFilter
    private let resolveApplication: (EventStreamApp) -> EventStreamObservedApplication?
    private let onWriteError: (Error) -> Void
    private var pendingRecords: [Pending] = []
    private(set) var processingTask: Task<Void, Never>?
    private var generation = UUID()

    private(set) var blockedCaptureContext: EventStreamBlockedCaptureContext?
    private(set) var observedApplications: [EventStreamObservedApplication] = []
    var onBlockedContextChange: ((EventStreamBlockedCaptureContext?) -> Void)?
    var onObservedApplicationsChange: (([EventStreamObservedApplication]) -> Void)?
    var pendingCount: Int { pendingRecords.count }
    var isProcessing: Bool { processingTask != nil }

    init(writer: EventStreamRecordWriting?, filter: EventStreamRecordFilter,
         resolveApplication: @escaping (EventStreamApp) -> EventStreamObservedApplication?,
         onWriteError: @escaping (Error) -> Void = {
             FileHandle.standardError.write(Data("Event stream write failed: \(String(reflecting: $0))\n".utf8))
         }) {
        self.writer = writer
        self.filter = filter
        self.resolveApplication = resolveApplication
        self.onWriteError = onWriteError
    }

    func receive(_ record: EventStreamRecord, isSuppressed: Bool = false) {
        guard writer != nil else { return }
        let boundary = record.kind == .sessionStarted || record.kind == .sessionEnded
        if boundary || (record.window?.url == nil && processingTask == nil && pendingRecords.isEmpty) {
            apply(.include, to: Pending(record: record, isSuppressed: isSuppressed))
        } else {
            pendingRecords.append(Pending(record: record, isSuppressed: isSuppressed))
            startProcessingIfNeeded()
        }
    }

    // Cancel and discard, without implicitly clearing policy state,
    // closing files or flushing a producer. The session owner controls that order.
    func cancelPendingRecords() {
        generation = UUID()
        processingTask?.cancel()
        processingTask = nil
        pendingRecords.removeAll()
    }

    func updateBlockedCaptureContext(_ context: EventStreamBlockedCaptureContext?) {
        guard blockedCaptureContext != context else { return }
        blockedCaptureContext = context
        onBlockedContextChange?(context)
    }

    // A new-session reset clears this array directly.
    func resetObservedApplications() { observedApplications.removeAll() }

    private func startProcessingIfNeeded() {
        guard processingTask == nil, !pendingRecords.isEmpty else { return }
        let epoch = generation
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.process(epoch: epoch)
        }
    }

    private func process(epoch: UUID) async {
        defer {
            // A cancelled policy can finish after another session starts work.
            // Never clear the new session's task from this old continuation.
            if generation == epoch { processingTask = nil }
        }
        while !pendingRecords.isEmpty {
            guard generation == epoch, !Task.isCancelled else { return }
            let pending = pendingRecords.removeFirst()
            let disposition = await filter.disposition(for: pending.record)
            guard generation == epoch, !Task.isCancelled else { return }
            apply(disposition, to: pending)
        }
    }

    private func apply(_ disposition: EventStreamRecordDisposition, to pending: Pending) {
        switch disposition {
        case .include:
            if pending.record.app != nil { updateBlockedCaptureContext(nil) }
            if !pending.isSuppressed { commit(pending.record) }
        case .blocked(let context):
            updateBlockedCaptureContext(context)
        }
    }

    private func commit(_ record: EventStreamRecord) {
        do { try writer?.append(record) }
        catch { onWriteError(error); return }
        // A first matching ID already at index zero is a
        // no-op, even if its metadata changed. Otherwise update/move to front.
        guard let app = record.app, let observed = resolveApplication(app) else { return }
        if let index = observedApplications.firstIndex(where: { $0.id == observed.id }) {
            if index == 0 { return }
            observedApplications.remove(at: index)
        }
        observedApplications.insert(observed, at: 0)
        onObservedApplicationsChange?(observedApplications)
    }

    deinit { processingTask?.cancel() }
}
