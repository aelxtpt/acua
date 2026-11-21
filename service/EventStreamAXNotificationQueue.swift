import Foundation

// Selection notification coalescing. Record construction
// and native key derivation remain the recorder's responsibilities.
@MainActor
final class EventStreamAXNotificationQueue {
    private let isRecording: () -> Bool
    private let sleep: (Duration) async throws -> Void
    private let lifetimeOwner:()->AnyObject?
    private let emit: (EventStreamRecord) -> Void
    private var records: [String: EventStreamRecord] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var pendingCount: Int { records.count }
    var scheduledCount: Int { tasks.count }

    init(isRecording: @escaping () -> Bool,
         sleep: @escaping (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
         lifetimeOwner:@escaping ()->AnyObject? = {nil},
         emit: @escaping (EventStreamRecord) -> Void) {
        self.isRecording = isRecording; self.sleep = sleep; self.emit = emit
        self.lifetimeOwner=lifetimeOwner
    }

    func enqueue(_ record: EventStreamRecord, key: String, notification: String) {
        records[key] = record
        tasks[key]?.cancel()
        let milliseconds = EventStreamRecorderAXObservationPolicy.debounceMilliseconds(notification: notification)
        let owner=lifetimeOwner()
        tasks[key] = Task { @MainActor [self,owner] in
            defer {withExtendedLifetime(owner) {}}
            // The delay continues after a non-cancellation sleep
            // error, then independently checks task cancellation and recording.
            try? await sleep(.milliseconds(milliseconds))
            guard !Task.isCancelled, isRecording() else { return }
            flush(key: key)
        }
    }

    func flushPendingRecords() {
        guard isRecording() else { return }
        flushAfterRecordingGuard()
    }

    // Recorder.flush checks its flag once, before text/terminal callbacks.
    func flushAfterRecordingGuard() {
        let keys = Array(records.keys)
        for key in keys { flush(key: key) }
    }

    func clearPendingRecords() {records.removeAll()}
    func clearScheduledTaskOwners() {tasks.removeAll()}

    private func flush(key: String) {
        guard let record = records.removeValue(forKey: key) else { return }
        tasks[key]?.cancel()
        tasks.removeValue(forKey: key)
        // Removal precedes emission, so a callback may queue the same key.
        emit(record)
    }

    func cancelPendingRecords() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        records.removeAll()
    }
}
