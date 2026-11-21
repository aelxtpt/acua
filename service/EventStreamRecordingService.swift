import Foundation

@MainActor protocol EventStreamSessionWriting: EventStreamRecordWriting {
    var sessionID: String { get }
    var directoryURL: URL { get }
    var eventsURL: URL { get }
    var suppressedEventsURL: URL? { get }
    func close()
}
extension EventStreamJSONLWriter: EventStreamSessionWriting {}

// The error has no LocalizedError override: NSError supplies the
// default message from this domain/code, while Swift reflection uses description.
enum EventStreamRecordingStorageError: Error, CustomNSError, CustomStringConvertible {
    case unavailable
    static var errorDomain: String { "ComputerUse.EventStreamStorageError" }
    var errorCode: Int { 0 }
    var errorUserInfo: [String: Any] { [:] }
    var description: String { "The protected Computer Use app-group container is unavailable." }
}

@MainActor struct EventStreamRecordingServiceIO {
    var now: () -> Date = Date.init
    var sessionID: () -> String = { UUID().uuidString }
    var makeWriter: (String, URL) throws -> any EventStreamSessionWriting = {
        try EventStreamJSONLWriter(sessionID: $0, rootDirectoryURL: $1)
    }
    var writeMetadata: (EventStreamMetadata, URL) throws -> Void = EventStreamMetadataStorage.write
    var truncate: (URL) throws -> Void = { try Data().write(to: $0, options: .atomic) }
    var sleep: (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }
    var onStateChanged: () -> Void = {}
    var onError: (Error) -> Void = {
        FileHandle.standardError.write(Data("Event stream session error: \(String(reflecting: $0))\n".utf8))
    }
}

// Session/storage owner. The shared native composition lives in EventStreamIPC.
@MainActor final class EventStreamRecordingService<Producer: EventStreamCaptureProducing> {
    private let coordinator: EventStreamCaptureCoordinator<Producer>
    private let rootDirectoryURL: URL?
    private let maximumDurationSeconds: Int
    private let io: EventStreamRecordingServiceIO
    private let shouldCaptureApplication: (Producer.Application) -> Bool
    let processor: EventStreamRecordProcessor
    private var writer: (any EventStreamSessionWriting)?
    private var subscription: EventStreamCaptureSubscription?
    private var metadataURL: URL?
    private var startedAt: Date?, endedAt: Date?, endReason: EventStreamEndReason?
    private var autoStopTask: Task<Void, Never>?
    private(set) var originatingThreadID: String?
    var isRecording: Bool { subscription != nil }

    init(coordinator: EventStreamCaptureCoordinator<Producer>, rootDirectoryURL: URL? = nil,
         maximumDurationSeconds: Int = 1800, filter: any EventStreamRecordFilter,
         resolveApplication: @escaping (EventStreamApp) -> EventStreamObservedApplication?,
         io: EventStreamRecordingServiceIO? = nil,
         shouldCaptureApplication: @escaping (Producer.Application) -> Bool = { _ in true }) {
        self.coordinator = coordinator
        self.rootDirectoryURL = rootDirectoryURL ?? EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay)
        self.maximumDurationSeconds = maximumDurationSeconds; self.io = io ?? .init()
        self.shouldCaptureApplication = shouldCaptureApplication
        processor = EventStreamRecordProcessor(writer: nil, filter: filter,
            resolveApplication: resolveApplication, onWriteError: self.io.onError)
    }

    func status() -> EventStreamSessionStatus {
        .init(isRecording: isRecording, sessionID: writer?.sessionID,
            sessionDirectoryPath: writer?.directoryURL.path, eventsPath: writer?.eventsURL.path,
            metadataPath: metadataURL?.path, suppressedEventsPath: writer?.suppressedEventsURL?.path,
            startedAt: startedAt, endedAt: endedAt, endReason: endReason,
            maxDurationSeconds: maximumDurationSeconds)
    }

    @discardableResult func start(originatingThreadID: String? = nil) throws -> EventStreamSessionStatus {
        // Active start is a status read; missing storage fails before reset.
        guard subscription == nil else { return status() }
        guard let rootDirectoryURL else { throw EventStreamRecordingStorageError.unavailable }
        resetForStart(at: io.now(), originatingThreadID: originatingThreadID)
        do {
            let next = try io.makeWriter(io.sessionID(), rootDirectoryURL)
            writer = next; processor.writer = next
            metadataURL = next.eventsURL.deletingLastPathComponent().appendingPathComponent("session.json")
            subscription = try coordinator.subscribe(shouldCapture: shouldCaptureApplication,
                onRecord: { [weak self] in self?.processor.receive($0) },
                onSuppressedRecord: { [weak self] in self?.processor.receive($0, isSuppressed: true) })
        } catch {
            cleanupFailedStart(); io.onError(error); throw error
        }
        writeMetadata()
        scheduleAutoStop()
        io.onStateChanged()
        return status()
    }

    @discardableResult func stop(reason: EventStreamEndReason) -> EventStreamSessionStatus {
        // End time/reason are visible to producer flush callbacks. The writer
        // remains installed until unsubscribe has emitted the session boundary.
        guard let subscription else { return status() }
        endedAt = io.now(); endReason = reason
        autoStopTask?.cancel(); autoStopTask = nil
        coordinator.unsubscribe(subscription)
        self.subscription = nil
        processor.cancelPendingRecords()
        writer?.close()
        if reason == .recordingControlsCancelled {
            for url in [writer?.eventsURL, writer?.suppressedEventsURL].compactMap({ $0 }) {
                do { try io.truncate(url) } catch { io.onError(error) }
            }
        }
        writeMetadata()
        processor.updateBlockedCaptureContext(nil)
        io.onStateChanged()
        return status()
    }

    func stopFromControls(discarded: Bool) -> String? {
        guard isRecording else { return nil }
        let threadID = originatingThreadID
        stop(reason: discarded ? .recordingControlsCancelled : .recordingControlsStopped)
        return threadID
    }

    private func resetForStart(at date: Date, originatingThreadID: String?) {
        startedAt = date; self.originatingThreadID = originatingThreadID
        processor.resetObservedApplications()
        processor.updateBlockedCaptureContext(nil)
        endedAt = nil; endReason = nil
        processor.cancelPendingRecords()
        writer?.close(); writer = nil; processor.writer = nil
        subscription = nil; metadataURL = nil
        autoStopTask?.cancel(); autoStopTask = nil
    }

    private func cleanupFailedStart() {
        startedAt = nil; originatingThreadID = nil; endedAt = nil; endReason = nil
        processor.updateBlockedCaptureContext(nil)
        processor.cancelPendingRecords()
        writer?.close(); writer = nil; processor.writer = nil
        if let subscription { coordinator.unsubscribe(subscription) }
        subscription = nil; metadataURL = nil
        autoStopTask?.cancel(); autoStopTask = nil
    }

    private func writeMetadata() {
        guard let writer, let metadataURL, let startedAt else { return }
        let metadata = EventStreamMetadata(id: writer.sessionID, eventsPath: writer.eventsURL.path,
            startedAt: startedAt, endedAt: endedAt, endReason: endReason,
            eventCount: nil, suppressedEventCount: nil)
        do { try io.writeMetadata(metadata, metadataURL) } catch { io.onError(error) }
    }

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        // Error and success continuations join here.
        // A non-cancellation sleep error still stops an active session.
        let duration = Duration.seconds(maximumDurationSeconds)
        autoStopTask = Task { [self] in
            try? await io.sleep(duration)
            guard !Task.isCancelled, isRecording else { return }
            stop(reason: .maxDuration)
        }
    }
}
