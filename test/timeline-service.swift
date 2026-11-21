import Foundation

private final class FixtureProducer: EventStreamCaptureProducing {
    typealias Application = String
    var isRecording = false
    var onRecordStored: ((EventStreamRecord) -> Void)?
    var onSuppressedRecordStored: ((EventStreamRecord) -> Void)?
    var shouldCaptureApplication: ((String) -> Bool)?
    var now: Date
    var refreshCount = 0

    init(now: Date) { self.now = now }
    func start() throws {
        isRecording = true
        onRecordStored?(makeSessionBoundaryRecord(kind: .sessionStarted))
    }
    func stop(emitSessionEnded: Bool) { isRecording = false }
    func flushPendingRecords() {}
    func refreshCurrentApplication() { refreshCount += 1 }
    func makeSessionBoundaryRecord(kind: EventStreamEventKind) -> EventStreamRecord {
        .init(id: 1, timestamp: now, kind: kind)
    }
}

private struct AllowFixture: EventStreamRecordFilter {
    func disposition(for record: EventStreamRecord) async -> EventStreamRecordDisposition { .include }
}

private final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@main private enum Tests {
    struct Failure: Error { let label: String }
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label: label) }
        print("PASS \(label)")
    }

    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }

    @MainActor static func run() async throws {
        let sandbox = URL(fileURLWithPath: "/private/tmp/cua-timeline-owner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let captureRoot = sandbox.appendingPathComponent("capture")
        let dataHome = sandbox.appendingPathComponent("agent-home")
        let summaryRoot = dataHome.appendingPathComponent("memories/extensions/timeline/resources")
        var now = Date(timeIntervalSince1970: 1_800_000_300)
        let producer = FixtureProducer(now: now), defaults = FixtureDefaults()
        let coordinator = EventStreamCaptureCoordinator(recorder: producer)
        let resolver = EventStreamApplicationResolver(runningApplication: { _ in nil }, applicationURL: { _ in nil },
            bundleDetails: { _ in nil }, executablePath: { _ in nil })
        var events: [[String: Any]] = [], errors: [Error] = [], generations = 0
        let owner = TimelineService(coordinator: coordinator, root: captureRoot, dataHome: dataHome,
            defaults: defaults, resolveBundleID: { $0 }, resolver: resolver, filter: AllowFixture(),
            loadInstructions: { "Owned instructions\n" }, summariser: .init(tenMinute: { _ in
                generations += 1
                return "# Owned summary\n"
            }, sixHour: { _, _ in "# Owned rollup\n" }), jitter: { .zero },
            recordTelemetry: { events.append($0) }, onError: { errors.append($0) }, now: { now })
        func call<T: Decodable>(_ route: TimelineOperation.Route, _ request: Any = [:]) throws -> T {
            let operation = try TimelineOperation(route: route, request: request)
            return try JSONDecoder().decode(T.self, from: operation.execute(on: owner, now: now))
        }
        func status(_ route: TimelineOperation.Route, _ request: Any = [:]) throws -> TimelineStatus {
            try call(route, request)
        }
        func expectError(_ route: TimelineOperation.Route, _ request: Any, _ code: CUErrorCode, _ label: String) throws {
            do {
                let operation = try TimelineOperation(route: route, request: request)
                _ = try operation.execute(on: owner, now: now)
                throw Failure(label: label)
            } catch let error as ServiceError {
                try check(error.code == code, label)
            }
        }

        let stopped = try status(.status, NSNull())
        try check(stopped.state == .stopped && stopped.eventStreamRootPath == captureRoot.path, "status route accepts an empty native request")
        let emptyMenu = owner.statusMenuHistory(now: now, calendar: .current)
        try check(emptyMenu.state == .stopped && emptyMenu.recentApplications.isEmpty
            && !emptyMenu.canClearHistory.lastTenMinutes && !emptyMenu.canClearHistory.lastHour
            && !emptyMenu.canClearHistory.lastDay, "stopped status menu reports empty history")
        try check(!FileManager.default.fileExists(atPath: sandbox.path), "status leaves storage absent")
        try expectError(.pause, [:], .unknownError, "pause while stopped")
        try expectError(.resume, [:], .unknownError, "resume while stopped")
        try expectError(.pause, ["duration": "invalid"], .couldNotGetRequestData, "malformed pause")
        try expectError(.clearHistory, ["scope": "interval"], .unknownError, "invalid history interval")
        let initial: TimelineSettings = try call(.getSettings)
        try check(initial.observation == .defaults, "get settings defaults")

        let active = try status(.start)
        try check(active.state == .running && active.startedAt == now && coordinator.subscriptionCount == 1,
                  "start subscribes and opens a segment")
        try check(FileManager.default.fileExists(atPath: active.currentSegmentEventsPath!), "start creates events file")
        let instructionURL = summaryRoot.deletingLastPathComponent().appendingPathComponent("instructions.md")
        let instructions = try String(contentsOf: instructionURL, encoding: .utf8)
        try check(instructions == "Owned instructions\n", "start prepares instructions")
        let repeated = try status(.start)
        try check(repeated == active && coordinator.subscriptionCount == 1, "start is idempotent")

        let paused = try status(.pause, ["duration": "thirty_minutes"])
        try check(paused.state == .paused && !producer.isRecording && defaults.values["timeline.pauseResumeDate"] as? Date == now.addingTimeInterval(1800),
                  "pause releases capture and persists resume date")
        let resumed = try status(.resume)
        try check(resumed.state == .running && defaults.values["timeline.pauseResumeDate"] == nil, "resume restores capture and clears timer")

        let blockRequest: [String: Any] = ["target": ["scope": "app", "bundleID": "example.blocked"], "observe": false]
        let blocked: TimelineSettings = try call(.updatePolicy, blockRequest)
        try check(blocked.observation.excludesApplication(bundleIdentifier: "example.blocked")
            && producer.shouldCaptureApplication?("example.blocked") == false, "policy update changes live capture")
        try check(producer.refreshCount == 1, "settings refresh the shared producer")
        let defaultsRequest: [String: Any] = ["settings": ["observation": [
            "defaultApplicationBehavior": "observe", "defaultURLBehavior": "do_not_observe", "allowlist": [], "blocklist": []]]]
        let updated: TimelineSettings = try call(.updateSettings, defaultsRequest)
        let disk = TimelineSettingsStorage.load(configurationRootURL: dataHome.appendingPathComponent("timeline"))
        try check(updated == disk && updated.observation.defaultURLBehavior == .doNotObserve, "update settings persists normalized wire value")

        let record = EventStreamRecord(id: 2, timestamp: now, kind: .sessionStarted)
        let app = EventStreamObservedApplication(id: "owned", name: "Owned", bundleIdentifier: "example.owned",
            bundleURL: nil, executableURL: nil)
        owner.recent.record(record, classification: .init(application: app, urlDomain: "owned.example"))
        let recent = owner.recentApplications(at: now.addingTimeInterval(600))
        try check(recent.count == 1 && recent[0].urlDomains.first?.isExcluded == true, "recent cutoff includes boundary and recomputes domain policy")
        let hidden = EventStreamObservedApplication(id: "apple", name: "Owned System", bundleIdentifier: "com.apple.owned",
            bundleURL: nil, executableURL: nil)
        owner.recent.record(record, classification: .init(application: hidden))
        try check(owner.recentApplications(at: now).map(\.application.id) == ["owned"], "recent list hides system-only entries")
        let menu = owner.statusMenuHistory(now: now, calendar: .current)
        try check(menu.state == .running && menu.recentApplications.map(\.id) == ["owned"],
            "running status menu includes visible recent applications")
        let recentMenu = menu.recentApplications[0]
        try check(recentMenu.lastSession.startedAt == ISO8601DateFormatter().string(from: now)
            && recentMenu.lastSession.endedAt == recentMenu.lastSession.startedAt
            && recentMenu.domains.first?.isExcluded == true, "status menu formats dates and applies current domain rules")
        _ = try status(.pause, ["duration": "thirty_minutes"])
        let pausedMenu = owner.statusMenuHistory(now: now, calendar: .current)
        try check(pausedMenu.state == .paused && pausedMenu.recentApplications.first?.lastSession.canClearHistory == false,
            "paused status menu disables clearing an application session")
        _ = try status(.resume)
        let interval = DateInterval(start: now.addingTimeInterval(-1200), end: now.addingTimeInterval(1200))
        try check(owner.canClearHistory(.interval(interval), now: now, calendar: .current), "history detects current segment")
        let summaryStore = TimelineMemorySummaryStore(memoryResourcesURL: summaryRoot)
        try TimelineMemorySummaryWriter(store: summaryStore).writeSummary("# Owned prior", sixHour: false, bucketStart: now.addingTimeInterval(-1))
        let menuWithSummary = owner.statusMenuHistory(now: now.addingTimeInterval(1), calendar: .current)
        try check(menuWithSummary.canClearHistory.lastTenMinutes && menuWithSummary.canClearHistory.lastHour
            && menuWithSummary.recentApplications.first?.lastSession.canClearHistory == true,
            "running status menu finds a summary overlapping the recent session")
        let clearRequest: [String: Any] = ["scope": "interval", "interval": [
            "start": interval.start.timeIntervalSinceReferenceDate, "end": interval.end.timeIntervalSinceReferenceDate]]
        let afterClear = try status(.clearHistory, clearRequest)
        let filesAfterClear = try summaryStore.listSummaries(sixHour: false)
        let eventsAfterClear = try Data(contentsOf: URL(fileURLWithPath: afterClear.currentSegmentEventsPath!))
        try check(afterClear.state == .running && filesAfterClear.isEmpty && eventsAfterClear.isEmpty, "clear history deletes summaries and reopens the active segment")
        try check(owner.recentApplications(at: now).isEmpty, "clear history prunes entries inside removed segment")
        try check(owner.statusMenuHistory(now: now, calendar: .current).recentApplications.isEmpty,
            "status menu no longer lists cleared sessions")
        try check((events.last?["@type"] as? String)?.hasSuffix(".TimelineHistoryCleared") == true
            && events.last?["scope"] as? String == "interval", "clear history emits scoped completion")

        now = now.addingTimeInterval(1)
        let ended = try status(.stop)
        try check(ended.state == .stopped && ended.endedAt == now && coordinator.subscriptionCount == 0, "stop finishes writer and releases capture")
        let count = events.count
        let stoppedAgain = try status(.stop)
        try check(stoppedAgain == ended && events.count == count, "stop is idempotent")
        try check(generations == 0 && errors.isEmpty, "clearing or stopping does not generate a summary")

        _ = try status(.start)
        now = now.addingTimeInterval(600)
        producer.now = now
        producer.onRecordStored?(producer.makeSessionBoundaryRecord(kind: .sessionStarted))
        let deadline = ContinuousClock.now + .seconds(3)
        while try summaryStore.listSummaries(sixHour: false).isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let generated = try summaryStore.listSummaries(sixHour: false)
        try check(generations == 1 && generated.count == 1, "completed live segment enqueues and writes memory")
        _ = try status(.stop)

        try FileManager.default.removeItem(at: summaryRoot)
        try Data("owned blocker".utf8).write(to: summaryRoot)
        let beforeFailure = events.count
        do {
            _ = try status(.clearHistory, clearRequest)
            throw Failure(label: "history should report a blocked summary directory")
        } catch is CocoaError {
            try check(events.count == beforeFailure, "failed history deletion emits no completion")
        }
    }
}
