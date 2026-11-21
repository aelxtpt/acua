import Foundation

/// Composes the capture lifecycle, settings, history, and memory on the main actor.
@MainActor final class TimelineService<Producer: EventStreamCaptureProducing> {
    private let coordinator: EventStreamCaptureCoordinator<Producer>
    private let root: URL?
    private let segmentStore: TimelineSegmentStore?
    private let summaryStore: TimelineMemorySummaryStore
    private let resources: TimelineResourcePreparation
    private let defaults: UserDefaults
    private let resolveBundleID: (Producer.Application) -> String?
    private let resolver: EventStreamApplicationResolver
    private let filter: any EventStreamRecordFilter
    private let memory: TimelineMemoryPipeline
    private let recordTelemetry: ([String: Any]) -> Void
    private let onError: (Error) -> Void
    private let now: () -> Date
    let recent = TimelineRecentApplicationStore()

    init(coordinator: EventStreamCaptureCoordinator<Producer>, root: URL?, dataHome: URL,
         defaults: UserDefaults, resolveBundleID: @escaping (Producer.Application) -> String?,
         resolver: EventStreamApplicationResolver, filter: any EventStreamRecordFilter,
         loadInstructions: @escaping () throws -> String, summariser: TimelineMemoryPipeline.Summariser,
         jitter: @escaping () -> Duration, recordTelemetry: @escaping ([String: Any]) -> Void,
         onError: @escaping (Error) -> Void, now: @escaping () -> Date = Date.init) {
        self.coordinator = coordinator
        self.root = root
        self.defaults = defaults
        self.resolveBundleID = resolveBundleID
        self.resolver = resolver
        self.filter = filter
        self.recordTelemetry = recordTelemetry
        self.onError = onError
        self.now = now
        segmentStore = root.map { TimelineSegmentStore(rootDirectoryURL: $0) }
        let extensionURL = dataHome.appendingPathComponent("memories/extensions/timeline", isDirectory: true)
        let summaryStore = TimelineMemorySummaryStore(memoryResourcesURL: extensionURL.appendingPathComponent("resources", isDirectory: true))
        self.summaryStore = summaryStore
        resources = TimelineResourcePreparation(eventStreamRootURL: root,
            configurationRootURL: dataHome.appendingPathComponent("timeline", isDirectory: true),
            memoryExtensionURL: extensionURL, loadInstructions: loadInstructions)
        memory = TimelineMemoryPipeline(store: summaryStore, summariser: summariser, delay: jitter,
            now: now, finished: { level, result, seconds in
                recordTelemetry(["@type": Self.telemetryType("MemorySummaryFinished"),
                    "summaryLevel": level.rawValue, "result": result.rawValue, "durationSeconds": seconds])
            }, onError: onError)
        _ = settings
    }

    private lazy var settings: TimelineSettingsCache = TimelineSettingsCache(configurationRootURL: resources.configurationRootURL,
        notificationObject: self, effects: .init(refreshCapture: { [weak self] in
            self?.coordinator.refreshIfRecording()
        }, recordUpdate: { [weak self] type, settings in
            self?.recordTelemetry(TimelineSettingsTelemetry.parameters(type: type, settings: settings))
        }))

    private lazy var processor: TimelineRecordProcessor = TimelineRecordProcessor(writer: { [weak self] in self?.lifecycle.segmentWriter },
        classifier: TimelineRecordClassifier(settings: { [weak self] in self?.settings.get() ?? .init(observation: .defaults) },
            resolver: resolver, filter: filter), recent: recent,
        onCompletedSegment: { [weak self] in self?.memory.enqueue($0) }, onError: onError)

    private lazy var lifecycle: TimelineLifecycle<Producer> = TimelineLifecycle(coordinator: coordinator, store: segmentStore,
        rootURL: root, defaults: defaults, hooks: .init(shouldCapture: { [weak self] app in
            guard let self else { return false }
            return !settings.get().observation.excludesApplication(bundleIdentifier: resolveBundleID(app))
        }, onRecord: { [weak self] in self?.processor.receive($0) },
           onSuppressedRecord: { [weak self] in self?.processor.receive($0, isSuppressed: true) },
           prepareStorage: resources.prepareStorage, prepareMemory: resources.prepareMemory,
           resetRecentApplications: { [weak self] in self?.recent.reset() },
           cancelPendingRecords: { [weak self] in self?.processor.cancelPendingRecords() },
           processCompletedSegment: { [weak self] metadata in
               guard let self else { return }
               do { try memory.recoverLatestSegment(metadata) }
               catch { onError(error) }
           }, recordEvent: { [weak self] (event: TimelineLifecycle<Producer>.Event) in
               self?.recordTelemetry(TimelineLifecycleTelemetry.parameters(event: event))
           }, scheduleResume: TimelineResumeScheduler.schedule, onError: onError), notificationObject: self, now: now)

    func start() throws -> TimelineStatus { try lifecycle.start() }
    func status() -> TimelineStatus { lifecycle.status() }
    func stop(reason: TimelineLifecycle<Producer>.StopReason) -> TimelineStatus { lifecycle.stop(reason: reason) }
    func pause(duration: TimelinePauseDuration?) throws -> TimelineStatus {
        if let duration { return try lifecycle.pause(for: duration) }
        return try lifecycle.pause()
    }
    func resume() throws -> TimelineStatus { try lifecycle.resume() }
    func getSettings() -> TimelineSettings { settings.get() }
    func updateSettings(_ value: TimelineSettings) throws -> TimelineSettings { try settings.update(value) }
    func updatePolicy(_ request: TimelineUpdateObservationPolicyRequest) throws -> TimelineSettings {
        switch request.target.scope {
        case .app:
            guard let id = request.target.bundleID else { throw TimelineError.invalidApplicationRule }
            return try settings.updateObservationPolicy(request.observe, forApplication: id)
        case .url:
            guard let domain = request.target.urlDomain else { throw TimelineError.invalidURLRule }
            return try settings.updateObservationPolicy(request.observe, forURLDomain: domain)
        }
    }

    func recentApplications(at date: Date) -> [TimelineRecentApplication] {
        recent.snapshot(now: date, observation: settings.get().observation)
    }

    func canClearHistory(_ scope: TimelineValidatedHistoryScope, now: Date, calendar: Calendar) -> Bool {
        TimelineHistoryAvailability.canClearHistory(scope, isPaused: lifecycle.state == .paused,
            now: now, calendar: calendar, segmentStore: segmentStore, memoryStore: summaryStore, onError: onError)
    }

    func statusMenuHistory(now: Date, calendar: Calendar) -> StatusMenuState.ComputerHistory {
        let formatter = ISO8601DateFormatter()
        let applications = recentApplications(at: now).map { recent in
            let app = recent.application
            let session = recent.lastSession
            let end = session.endedAt ?? now
            let interval = DateInterval(start: min(session.startedAt, end), end: end)
            return StatusMenuState.RecentApplication(
                id: app.id, name: app.name, bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL?.absoluteString,
                isExcluded: recent.isExcluded,
                lastSession: .init(startedAt: formatter.string(from: session.startedAt),
                    endedAt: session.endedAt.map(formatter.string(from:)),
                    canClearHistory: canClearHistory(.applicationSession(interval), now: now, calendar: calendar)),
                domains: recent.urlDomains.map { .init(domain: $0.domain, isExcluded: $0.isExcluded) })
        }
        return .init(state: lifecycle.state, canClearHistory: .init(
            lastTenMinutes: canClearHistory(.lastTenMinutes, now: now, calendar: calendar),
            lastHour: canClearHistory(.lastHour, now: now, calendar: calendar),
            lastDay: canClearHistory(.lastDay, now: now, calendar: calendar)), recentApplications: applications)
    }

    func clearHistory(_ scope: TimelineValidatedHistoryScope, now date: Date, calendar: Calendar) throws {
        let interval = scope.resolvedInterval(now: date, calendar: calendar)
        memory.cancel(overlapping: interval)
        let removed: [DateInterval]
        if let writer = lifecycle.segmentWriter {
            removed = try writer.clearHistory(overlapping: interval, now: date)
        } else {
            removed = try segmentStore?.removeSegments(overlapping: interval) ?? []
        }
        try summaryStore.removeSummaries(overlapping: interval)
        recent.removeEntries(in: removed)
        recordTelemetry(["@type": Self.telemetryType("HistoryCleared"), "scope": scope.wireName.rawValue])
    }

    private static func telemetryType(_ name: String) -> String {
        "acua.telemetry.v1.Timeline" + name
    }
}
