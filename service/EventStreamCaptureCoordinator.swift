import Foundation

// The native recorder will supply NSRunningApplication as Application. Keeping
// its type here allows lifecycle tests without starting global input capture.
protocol EventStreamCaptureProducing: AnyObject {
    associatedtype Application
    var isRecording: Bool { get }
    var onRecordStored: ((EventStreamRecord) -> Void)? { get set }
    var onSuppressedRecordStored: ((EventStreamRecord) -> Void)? { get set }
    var shouldCaptureApplication: ((Application) -> Bool)? { get set }
    func start() throws
    func flushPendingRecords()
    func stop(emitSessionEnded: Bool)
    func makeSessionBoundaryRecord(kind: EventStreamEventKind) -> EventStreamRecord
    func refreshCurrentApplication()
}

struct EventStreamCaptureSubscription: Hashable {
    fileprivate let id: UUID
}

// The coordinator is MainActor isolated; all operations and producer
// callbacks must run on the main thread.
final class EventStreamCaptureCoordinator<Producer: EventStreamCaptureProducing> {
    private struct Sink {
        let shouldCapture: (Producer.Application) -> Bool
        let onRecord: (EventStreamRecord) -> Void
        let onSuppressedRecord: ((EventStreamRecord) -> Void)?
    }
    private let recorder: Producer
    private var sinks: [UUID: Sink] = [:]
    private var removing: Set<UUID> = []

    init(recorder: Producer) { self.recorder = recorder }

    var subscriptionCount: Int { precondition(Thread.isMainThread); return sinks.count }

    func subscribe(shouldCapture: @escaping (Producer.Application) -> Bool,
                   onRecord: @escaping (EventStreamRecord) -> Void,
                   onSuppressedRecord: ((EventStreamRecord) -> Void)? = nil) throws -> EventStreamCaptureSubscription {
        precondition(Thread.isMainThread)
        let subscription = EventStreamCaptureSubscription(id: UUID())
        sinks[subscription.id] = Sink(shouldCapture: shouldCapture, onRecord: onRecord, onSuppressedRecord: onSuppressedRecord)
        let wasRecording = recorder.isRecording
        installCallbacks()
        do {
            if wasRecording {
                onRecord(recorder.makeSessionBoundaryRecord(kind: .sessionStarted))
                refreshIfRecording()
            } else {
                try recorder.start()
            }
            return subscription
        } catch {
            sinks.removeValue(forKey: subscription.id)
            if sinks.isEmpty { clearCallbacks() }
            throw error
        }
    }

    func unsubscribe(_ subscription: EventStreamCaptureSubscription) {
        precondition(Thread.isMainThread)
        let id = subscription.id
        guard sinks[id] != nil, removing.insert(id).inserted else { return }
        defer { removing.remove(id) }
        recorder.flushPendingRecords()
        // A flush callback may change subscriptions. Never stop another sink
        // because an earlier callback removed this one.
        guard let sink = sinks[id] else { return }
        sink.onRecord(recorder.makeSessionBoundaryRecord(kind: .sessionEnded))
        guard sinks[id] != nil else { return }
        if sinks.count == 1 {
            recorder.stop(emitSessionEnded: false)
            sinks.removeValue(forKey: id)
            clearCallbacks()
        } else {
            sinks.removeValue(forKey: id)
            refreshIfRecording()
        }
    }

    private func installCallbacks() {
        recorder.onRecordStored = { [weak self] record in
            precondition(Thread.isMainThread)
            // Snapshot before invoking consumers (copy-on-write iteration): a
            // consumer may modify subscriptions.
            let snapshot = self.map { Array($0.sinks.values) } ?? []
            for sink in snapshot { sink.onRecord(record) }
        }
        recorder.onSuppressedRecordStored = { [weak self] record in
            precondition(Thread.isMainThread)
            let snapshot = self.map { Array($0.sinks.values) } ?? []
            for sink in snapshot { sink.onSuppressedRecord?(record) }
        }
        recorder.shouldCaptureApplication = { [weak self] application in
            precondition(Thread.isMainThread)
            let snapshot = self.map { Array($0.sinks.values) } ?? []
            return snapshot.contains { $0.shouldCapture(application) }
        }
    }

    func refreshIfRecording() {
        precondition(Thread.isMainThread)
        if recorder.isRecording { recorder.refreshCurrentApplication() }
    }

    private func clearCallbacks() {
        recorder.onRecordStored = nil
        recorder.onSuppressedRecordStored = nil
        recorder.shouldCaptureApplication = nil
    }
}
