import Foundation
import Darwin

private enum Failure: Error { case fixture }
/// A throwaway app bundle whose Info.plist names `group` as its app group, or none when nil.
private func groupBundle(_ group: String?) throws -> Bundle {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("cua-group-\(UUID().uuidString).app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": "com.example.acua.group-fixture", "CFBundlePackageType": "APPL"]
    if let group { info[EventStreamStorageConfiguration.applicationGroupInfoKey] = group }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return Bundle(url: app)!
}
private final class ContainerFileManager: FileManager, @unchecked Sendable {
    var requestedGroups: [String] = []
    var result: URL?
    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        requestedGroups.append(groupIdentifier)
        return result
    }
}
@MainActor private final class Sleeper {
    var durations: [Duration] = []
    var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    func sleep(_ duration: Duration) async throws {
        let id = durations.count; durations.append(duration)
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func finish(_ id: Int, error: Error? = nil) {
        guard let item = pending.removeValue(forKey: id) else { return }
        if let error { item.resume(throwing: error) } else { item.resume() }
    }
}
@MainActor private final class Filter: EventStreamRecordFilter {
    var pending: CheckedContinuation<EventStreamRecordDisposition, Never>?
    func disposition(for record: EventStreamRecord) async -> EventStreamRecordDisposition {
        await withCheckedContinuation { pending = $0 }
    }
}
@MainActor private final class Writer: EventStreamSessionWriting {
    let sessionID: String, directoryURL: URL, eventsURL: URL
    var suppressedEventsURL: URL?
    var records: [EventStreamRecord] = [], closed = false
    var closeHook: (() -> Void)?
    init(_ id: String, _ root: URL) {
        sessionID = id; directoryURL = root.appendingPathComponent(id)
        eventsURL = directoryURL.appendingPathComponent("events.jsonl")
    }
    func append(_ record: EventStreamRecord) throws { if !closed { records.append(record) } }
    func close() { closed = true; closeHook?() }
}
@MainActor private final class Producer: @preconcurrency EventStreamCaptureProducing {
    typealias Application = String
    var isRecording = false
    var onRecordStored: ((EventStreamRecord) -> Void)?
    var onSuppressedRecordStored: ((EventStreamRecord) -> Void)?
    var shouldCaptureApplication: ((String) -> Bool)?
    var starts = 0, stops = 0, flushes = 0, sequence = 0, failStart = false
    var flushHook: (() -> Void)?
    func record(_ kind: EventStreamEventKind, url: String? = nil) -> EventStreamRecord {
        sequence += 1
        return .init(id: sequence, timestamp: Date(timeIntervalSince1970: Double(sequence)), kind: kind,
            app: kind == .windowChanged ? .init(name: "Owned", secureInput: false, processIdentifier: 42) : nil,
            window: url.map { .init(url: $0) })
    }
    func makeSessionBoundaryRecord(kind: EventStreamEventKind) -> EventStreamRecord { record(kind) }
    func start() throws {
        starts += 1
        if failStart { throw Failure.fixture }
        isRecording = true; onRecordStored?(record(.sessionStarted))
    }
    func flushPendingRecords() { flushes += 1; flushHook?() }
    func stop(emitSessionEnded: Bool) { stops += 1; isRecording = false }
    func refreshCurrentApplication() {}
}

@main enum Tests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ name: String, _ value: Bool) {
            if !value { print("FAIL: \(name)"); fatalError(name) }
            checks += 1; print("PASS: \(name)")
        }
        func pump(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            precondition(done(), "Fixture continuation did not settle")
        }
        typealias Service = EventStreamRecordingService<Producer>
        let storageError = EventStreamRecordingStorageError.unavailable
        let nativeError = storageError as NSError
        check("missing-container NSError domain and code", nativeError.domain == "ComputerUse.EventStreamStorageError" && nativeError.code == 0)
        check("missing-container error has empty user info", nativeError.userInfo.isEmpty)
        check("missing-container default localized message", nativeError.localizedDescription == "The operation couldn’t be completed. (ComputerUse.EventStreamStorageError error 0.)")
        check("missing-container Swift description", String(reflecting: storageError) == "The protected Computer Use app-group container is unavailable.")
        let producer = Producer(), coordinator = EventStreamCaptureCoordinator(recorder: producer)
        let filter = Filter(), sleeper = Sleeper(), root = URL(fileURLWithPath: "/tmp/owned-recording-service")
        let app = EventStreamObservedApplication(id: "owned", name: "Owned", bundleIdentifier: nil, bundleURL: nil, executableURL: nil)
        var writers: [Writer] = [], metadata: [EventStreamMetadata] = [], truncated: [URL] = []
        var tick = 100, serial = 0, notifications = 0, errors = 0, writerFailure = false
        var io = EventStreamRecordingServiceIO()
        io.now = { tick += 1; return Date(timeIntervalSince1970: Double(tick)) }
        io.sessionID = { serial += 1; return "session-\(serial)" }
        io.makeWriter = { id, root in
            if writerFailure { throw Failure.fixture }
            let writer = Writer(id, root); writers.append(writer); return writer
        }
        io.writeMetadata = { item, _ in metadata.append(item) }
        io.truncate = { url in truncated.append(url) }
        io.sleep = { try await sleeper.sleep($0) }
        io.onStateChanged = { notifications += 1 }
        io.onError = { _ in errors += 1 }
        let service = Service(coordinator: coordinator, rootDirectoryURL: root, filter: filter,
            resolveApplication: { _ in app }, io: io)
        check("initial status is inactive without invented files or dates", !service.status().isRecording && service.status().sessionID == nil && service.status().startedAt == nil)
        check("default duration is 1800 seconds", service.status().maxDurationSeconds == 1800)
        let beforeStop = service.stop(reason: .toolStopped)
        check("inactive stop leaves state and clock untouched", beforeStop == service.status() && tick == 100 && notifications == 0)
        let started = try service.start(originatingThreadID: "thread-owned")
        check("start installs one capture subscription", started.isRecording && coordinator.subscriptionCount == 1 && producer.starts == 1)
        check("service capture policy includes applications", producer.shouldCaptureApplication?("Owned") == true)
        check("writer exists before synchronous initial boundary", writers[0].records.map(\.kind) == [.sessionStarted])
        check("session status reflects actual writer paths", started.sessionID == "session-1" && started.eventsPath == writers[0].eventsURL.path && started.sessionDirectoryPath == writers[0].directoryURL.path)
        check("metadata path is session.json next to events", started.metadataPath == writers[0].directoryURL.appendingPathComponent("session.json").path && started.suppressedEventsPath == nil)
        check("start stores supplied telemetry thread and entry timestamp", service.originatingThreadID == "thread-owned" && started.startedAt == Date(timeIntervalSince1970: 101))
        check("metadata uses nil counts and no end fields", metadata.count == 1 && metadata[0].eventCount == nil && metadata[0].suppressedEventCount == nil && metadata[0].endReason == nil)
        check("start posts exactly one state notification", notifications == 1)
        pump { sleeper.durations.count == 1 }
        check("automatic stop sleeps for the configured duration", sleeper.durations == [.seconds(1800)])
        let repeated = try service.start(originatingThreadID: "ignored")
        check("repeated start returns identical status without side effects", repeated == started && serial == 1 && tick == 101 && notifications == 1 && metadata.count == 1)
        check("repeated start preserves the first telemetry thread", service.originatingThreadID == "thread-owned")

        producer.onRecordStored?(producer.record(.windowChanged))
        check("committed app is tracked by processor", service.processor.observedApplications == [app])
        producer.onSuppressedRecordStored?(producer.record(.keyboardTextInput))
        check("suppressed input never enters events writer", !writers[0].records.contains { $0.kind == .keyboardTextInput })
        producer.onRecordStored?(producer.record(.windowChanged, url: "https://owned.example/"))
        pump { filter.pending != nil }
        check("URL-bearing record awaits required real policy dependency", service.processor.isProcessing && writers[0].records.count == 2)
        var flushObservedEnd = false
        producer.flushHook = {
            flushObservedEnd = service.status().endedAt == Date(timeIntervalSince1970: 102) && service.status().endReason == .toolStopped
            producer.onRecordStored?(producer.record(.keyboardSubmit))
        }
        let stopped = service.stop(reason: .toolStopped)
        check("end time and reason precede producer flush", flushObservedEnd)
        check("stop removes subscription and stops final producer", !stopped.isRecording && coordinator.subscriptionCount == 0 && producer.stops == 1)
        check("boundary bypasses awaiting policy while queued flush is discarded", writers[0].records.map(\.kind) == [.sessionStarted, .windowChanged, .sessionEnded])
        check("stop closes writer after boundary and clears pending queue", writers[0].closed && !service.processor.isProcessing && service.processor.pendingCount == 0)
        check("stopped status preserves session paths and start time", stopped.sessionID == started.sessionID && stopped.eventsPath == started.eventsPath && stopped.metadataPath == started.metadataPath && stopped.startedAt == started.startedAt)
        check("normal stop preserves events and writes end metadata", truncated.isEmpty && metadata.count == 2 && metadata[1].endedAt == stopped.endedAt && metadata[1].endReason == .toolStopped)
        check("normal stop posts one state notification", notifications == 2)
        let stoppedAgain = service.stop(reason: .recordingControlsCancelled)
        check("repeated stop preserves first reason and does not truncate", stoppedAgain == stopped && truncated.isEmpty && tick == 102 && notifications == 2)
        filter.pending?.resume(returning: .blocked(.init(application: app, normalizedURL: URL(string: "https://owned.example/")!))); filter.pending = nil
        sleeper.finish(0)
        pump { sleeper.pending.isEmpty }

        producer.flushHook = nil
        let restarted = try service.start()
        pump { sleeper.durations.count == 2 }
        check("restart creates new writer and session identity", restarted.sessionID == "session-2" && writers.count == 2 && producer.starts == 2)
        check("restart clears previous end date reason thread and observed apps", restarted.endedAt == nil && restarted.endReason == nil && service.originatingThreadID == nil && service.processor.observedApplications.isEmpty)
        check("old late policy cannot contaminate new session", service.processor.blockedCaptureContext == nil && writers[1].records.map(\.kind) == [.sessionStarted])
        let suppressed = writers[1].directoryURL.appendingPathComponent("owned-suppressed.jsonl")
        writers[1].suppressedEventsURL = suppressed
        var closedBeforeTruncate = false
        writers[1].closeHook = { closedBeforeTruncate = true }
        let cancelled = service.stop(reason: .recordingControlsCancelled)
        check("cancel closes writer and truncates both actual event URLs", closedBeforeTruncate && truncated == [writers[1].eventsURL, suppressed])
        check("cancel retains session directory and metadata references", cancelled.sessionDirectoryPath == restarted.sessionDirectoryPath && cancelled.metadataPath == restarted.metadataPath && cancelled.endReason == .recordingControlsCancelled)
        check("cancel persists metadata with nil event counts", metadata.last?.endReason == .recordingControlsCancelled && metadata.last?.eventCount == nil && metadata.last?.suppressedEventCount == nil)
        sleeper.finish(1, error: CancellationError())
        _ = try service.start()
        pump { sleeper.durations.count == 3 }
        sleeper.finish(2, error: Failure.fixture)
        pump { !service.isRecording }
        check("non-cancellation sleep error still automatically stops active session", service.status().endReason == .maxDuration && producer.stops == 3)
        check("automatic stop retains last writer identity", service.status().sessionID == "session-3")

        writerFailure = true
        do { _ = try service.start(); fatalError("Expected writer failure") } catch Failure.fixture {}
        check("writer construction failure clears prior status and telemetry", !service.isRecording && service.status().sessionID == nil && service.status().startedAt == nil && service.status().endedAt == nil && service.originatingThreadID == nil)
        check("writer failure reports error without notification or subscription", errors == 1 && notifications == 6 && coordinator.subscriptionCount == 0)
        writerFailure = false; producer.failStart = true
        do { _ = try service.start(); fatalError("Expected producer failure") } catch Failure.fixture {}
        check("producer start failure closes created writer and clears metadata path", writers.last?.closed == true && service.status().metadataPath == nil && service.status().sessionID == nil)
        check("producer failure removes callbacks and subscription", coordinator.subscriptionCount == 0 && producer.onRecordStored == nil && producer.onSuppressedRecordStored == nil && errors == 2)

        let unavailable = Service(coordinator: coordinator, rootDirectoryURL: nil, filter: filter, resolveApplication: { _ in app }, io: io)
        let unavailableBefore = unavailable.status(), timeBefore = tick
        do { _ = try unavailable.start(); fatalError("Expected missing storage") } catch EventStreamRecordingStorageError.unavailable {}
        check("missing root fails before resetting state or sampling time", unavailable.status() == unavailableBefore && tick == timeBefore)
        check("missing root cannot publish recording success", !unavailable.isRecording && coordinator.subscriptionCount == 0)

        let blocked = EventStreamBlockedCaptureContext(application: app, normalizedURL: URL(string: "https://www.owned.example/path")!)
        let anotherApp = EventStreamObservedApplication(id: "other", name: "Other", bundleIdentifier: nil, bundleURL: nil, executableURL: nil)
        let sameSite = EventStreamBlockedCaptureContext(application: anotherApp, normalizedURL: blocked.normalizedURL)
        let differentPath = EventStreamBlockedCaptureContext(application: app, normalizedURL: URL(string: "https://www.owned.example/other")!)
        var warning = EventStreamRecordingWarningState()
        warning.update(blocked)
        check("a blocked capture context makes a warning visible", warning.visibleContext == blocked)
        warning.dismiss()
        warning.update(nil)
        warning.update(sameSite)
        check("dismissal survives context clearing and uses the full URL across applications", warning.visibleContext == nil)
        warning.update(differentPath)
        check("a different blocked URL can warn in the same recording", warning.visibleContext == differentPath)
        warning = EventStreamRecordingWarningState()
        warning.update(blocked)
        check("a new recording can warn about a previously dismissed address", warning.visibleContext == blocked)
        check("warning title uses host without www and falls back to absolute URL without host",
              EventStreamRecordingWarningState.siteName(for: blocked.normalizedURL) == "owned.example" &&
              EventStreamRecordingWarningState.siteName(for: URL(string: "about:blank")!) == "about:blank")

        let sharedProducer = Producer(), sharedCoordinator = EventStreamCaptureCoordinator(recorder: sharedProducer), sharedSleeper = Sleeper()
        var external: [EventStreamRecord] = []
        let externalToken = try sharedCoordinator.subscribe(shouldCapture: { _ in false }, onRecord: { external.append($0) })
        var sharedIO = io; sharedIO.sleep = { try await sharedSleeper.sleep($0) }
        let shared = Service(coordinator: sharedCoordinator, rootDirectoryURL: root, filter: filter, resolveApplication: { _ in app }, io: sharedIO)
        _ = try shared.start()
        pump { sharedSleeper.durations.count == 1 }
        check("service joins active producer without restarting its sources", sharedProducer.starts == 1 && sharedCoordinator.subscriptionCount == 2 && shared.isRecording)
        _ = shared.stop(reason: .serviceTerminated)
        check("service stop preserves another subscriber and active producer", !shared.isRecording && sharedProducer.isRecording && sharedProducer.stops == 0 && sharedCoordinator.subscriptionCount == 1)
        check("service end boundary is routed only to departing sink", !external.contains { $0.kind == .sessionEnded })
        sharedCoordinator.unsubscribe(externalToken); sharedSleeper.finish(0, error: CancellationError())

        var failIO = io, failMetadata = 0, failTruncations = 0, reportedErrors = 0
        let failSleeper = Sleeper(), failProducer = Producer()
        failIO.sleep = { try await failSleeper.sleep($0) }
        failIO.writeMetadata = { _, _ in failMetadata += 1; throw Failure.fixture }
        failIO.truncate = { _ in failTruncations += 1; if failTruncations == 1 { throw Failure.fixture } }
        failIO.onError = { _ in reportedErrors += 1 }
        let failService = Service(coordinator: EventStreamCaptureCoordinator(recorder: failProducer), rootDirectoryURL: root,
            filter: filter, resolveApplication: { _ in nil }, io: failIO)
        let failStarted = try failService.start()
        pump { failSleeper.durations.count == 1 }
        check("metadata write failure is reported while recording remains active", failStarted.isRecording && failMetadata == 1 && reportedErrors == 1)
        writers.last?.suppressedEventsURL = root.appendingPathComponent("owned-second-output")
        _ = failService.stop(reason: .recordingControlsCancelled)
        check("truncation failure still attempts the next file and end metadata", failTruncations == 2 && failMetadata == 2 && reportedErrors == 3)
        check("storage cleanup errors do not leave recording active", !failService.isRecording && writers.last?.closed == true)
        failSleeper.finish(0, error: CancellationError())

        let retainedSleeper = Sleeper(), retainedProducer = Producer()
        var retainedIO = io; retainedIO.sleep = { try await retainedSleeper.sleep($0) }
        var retained: Service? = Service(coordinator: EventStreamCaptureCoordinator(recorder: retainedProducer), rootDirectoryURL: root,
            filter: filter, resolveApplication: { _ in nil }, io: retainedIO)
        weak let weakRetained = retained
        _ = try retained?.start(); retained = nil
        pump { retainedSleeper.durations.count == 1 }
        check("automatic deadline task strongly retains its session owner", weakRetained != nil)
        retainedSleeper.finish(0)
        pump { weakRetained == nil }
        check("owner releases after automatic stop task unwinds", retainedProducer.stops == 1)

        for duration in [-1, 0, Int.max] {
            let edgeSleeper = Sleeper(), edgeProducer = Producer()
            var edgeIO = io; edgeIO.sleep = { try await edgeSleeper.sleep($0) }
            let edge = Service(coordinator: EventStreamCaptureCoordinator(recorder: edgeProducer), rootDirectoryURL: root,
                maximumDurationSeconds: duration, filter: filter, resolveApplication: { _ in nil }, io: edgeIO)
            _ = try edge.start(); pump { edgeSleeper.durations.count == 1 }
            check("duration edge \(duration) preserves signed wide duration and status", edgeSleeper.durations == [.seconds(duration)] && edge.status().maxDurationSeconds == duration)
            _ = edge.stop(reason: .toolStopped); edgeSleeper.finish(0, error: CancellationError())
        }

        // Native lookup is exercised through FileManager's actual override
        // point. It never looks up or modifies the real shared app container.
        check("unconfigured storage has no recording root", EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay) == nil)
        check("unconfigured storage has no Timeline root", EventStreamStorageConfiguration.rootDirectoryURL(for: .timeline) == nil)
        let configuredContainer = FileManager.default.temporaryDirectory.appendingPathComponent("cua-container-😀-\(UUID().uuidString)", isDirectory: true)
        let expectedRecording = configuredContainer.appendingPathComponent("Library/Caches/ComputerUse/RecordAndReplay", isDirectory: true)
        let expectedTimeline = configuredContainer.appendingPathComponent("Library/Caches/ComputerUse/Timeline", isDirectory: true)
        let lookup = ContainerFileManager(); lookup.result = configuredContainer
        EventStreamStorageConfiguration.configureNative(fileManager: lookup, bundle: try groupBundle(nil))
        check("a bundle without a group identifier performs no native lookup", lookup.requestedGroups.isEmpty && EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay) == nil)
        let configuredGroup = "TESTTEAM01.com.aex.computeruse", configuredBundle = try groupBundle(configuredGroup)
        EventStreamStorageConfiguration.configureNative(fileManager: lookup, bundle: configuredBundle)
        check("native lookup uses the bundle's application group identifier exactly once", lookup.requestedGroups == [configuredGroup])
        check("recording root appends the RecordAndReplay directory components", EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay) == expectedRecording)
        check("Timeline root uses the Timeline resolver branch", EventStreamStorageConfiguration.rootDirectoryURL(for: .timeline) == expectedTimeline)
        check("root resolution preserves directory URL semantics", EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay)?.hasDirectoryPath == true)
        check("lookup and root resolution do not create directories", !FileManager.default.fileExists(atPath: configuredContainer.path))
        lookup.result = nil
        EventStreamStorageConfiguration.configureNative(fileManager: lookup, bundle: configuredBundle)
        check("failed native lookup replaces an earlier configured container", lookup.requestedGroups.count == 2 && EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay) == nil)
        check("missing native container does not fall back to Timeline or home storage", EventStreamStorageConfiguration.rootDirectoryURL(for: .timeline) == nil)

        var rootSnapshots: [URL] = []
        let configurationSleeper = Sleeper()
        var configurationIO = io
        configurationIO.makeWriter = { id, root in rootSnapshots.append(root); return Writer(id, root) }
        configurationIO.sleep = { try await configurationSleeper.sleep($0) }
        let unavailableSnapshot = Service(coordinator: EventStreamCaptureCoordinator(recorder: Producer()),
            filter: filter, resolveApplication: { _ in nil }, io: configurationIO)
        EventStreamStorageConfiguration.configure(appGroupContainerURL: configuredContainer)
        let configuredSnapshot = Service(coordinator: EventStreamCaptureCoordinator(recorder: Producer()),
            filter: filter, resolveApplication: { _ in nil }, io: configurationIO)
        let explicitRoot = configuredContainer.appendingPathComponent("explicit-override", isDirectory: false)
        let explicitSnapshot = Service(coordinator: EventStreamCaptureCoordinator(recorder: Producer()), rootDirectoryURL: explicitRoot,
            filter: filter, resolveApplication: { _ in nil }, io: configurationIO)
        EventStreamStorageConfiguration.configure(appGroupContainerURL: configuredContainer.appendingPathComponent("changed"))
        do { _ = try unavailableSnapshot.start(); check("constructor keeps missing root even after configuration becomes available", false) }
        catch EventStreamRecordingStorageError.unavailable { check("constructor keeps missing root even after configuration becomes available", rootSnapshots.isEmpty) }
        _ = try configuredSnapshot.start()
        pump { configurationSleeper.durations.count == 1 }
        check("default root is copied at construction before configuration changes", rootSnapshots == [expectedRecording])
        _ = configuredSnapshot.stop(reason: .toolStopped); configurationSleeper.finish(0, error: CancellationError())
        _ = try explicitSnapshot.start()
        pump { configurationSleeper.durations.count == 2 }
        check("explicit root overrides configured storage without appending directories", rootSnapshots == [expectedRecording, explicitRoot])
        _ = explicitSnapshot.stop(reason: .toolStopped); configurationSleeper.finish(1, error: CancellationError())
        EventStreamStorageConfiguration.configure(appGroupContainerURL: nil)
        check("explicit nil configuration clears both derived roots", EventStreamStorageConfiguration.rootDirectoryURL(for: .recordAndReplay) == nil && EventStreamStorageConfiguration.rootDirectoryURL(for: .timeline) == nil)

        // Real filesystem proof uses only an owned disposable directory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-recording-storage-\(UUID().uuidString)")
        defer {
            EventStreamStorageConfiguration.configure(appGroupContainerURL: nil)
            try? FileManager.default.removeItem(at: directory)
        }
        EventStreamStorageConfiguration.configure(appGroupContainerURL: directory)
        let realProducer = Producer(), realCoordinator = EventStreamCaptureCoordinator(recorder: realProducer), realSleeper = Sleeper()
        var realIO = EventStreamRecordingServiceIO(); realIO.sleep = { try await realSleeper.sleep($0) }
        let real = Service(coordinator: realCoordinator, filter: filter, resolveApplication: { _ in nil }, io: realIO)
        let realStatus = try real.start(originatingThreadID: "owned-recording-thread")
        pump { realSleeper.durations.count == 1 }
        check("native writer uses resolved container root and session directory", URL(fileURLWithPath: realStatus.sessionDirectoryPath!).deletingLastPathComponent().path == directory.appendingPathComponent("Library/Caches/ComputerUse/RecordAndReplay").path)
        check("native storage writes real session-start JSONL", try String(contentsOfFile: realStatus.eventsPath!, encoding: .utf8).contains("session.started"))
        check("discard hands back the original thread after stopping the recording",
              real.stopFromControls(discarded: true) == "owned-recording-thread" && !real.isRecording)
        check("duplicate recording-control clicks produce no additional handoff",
              real.stopFromControls(discarded: true) == nil)
        check("native cancel atomically empties actual events file", try Data(contentsOf: URL(fileURLWithPath: realStatus.eventsPath!)).isEmpty)
        let realMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: realStatus.metadataPath!))) as! [String: Any]
        check("native cancel retains valid end metadata", realMetadata["endReason"] as? String == "recording_controls_cancelled" && realMetadata["eventCount"] == nil && realMetadata["suppressedEventCount"] == nil)
        check("native cancelled session directory remains for status", FileManager.default.fileExists(atPath: realStatus.sessionDirectoryPath!))
        realSleeper.finish(0, error: CancellationError())
        let kept = try real.start(originatingThreadID: "kept-recording-thread")
        pump { realSleeper.durations.count == 2 }
        let keptThread = real.stopFromControls(discarded: false)
        let keptEvents = try Data(contentsOf: URL(fileURLWithPath: kept.eventsPath!))
        check("stop hands back the original thread and preserves the recording",
              keptThread == "kept-recording-thread" && real.status().endReason == .recordingControlsStopped &&
              !keptEvents.isEmpty)
        realSleeper.finish(1, error: CancellationError())
        print("Recording service checks: \(checks)")
    }
}
