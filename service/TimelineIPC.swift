import AppKit
import Foundation
import OSLog

@MainActor enum TimelineNativeOwner {
    private static var existing: TimelineService<EventStreamNativeRecorder>?
    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "Timeline")

    static var shared: TimelineService<EventStreamNativeRecorder> {
        if let existing { return existing }
        // Settings and memory resources live in ACUA's own data directory.
        let dataHome = AcuaConfigurationLocation.directoryURL().standardizedFileURL
        let root = EventStreamStorageConfiguration.rootDirectoryURL(for: .timeline)
        let resolver = EventStreamApplicationResolver()
        let policy = EventStreamRecordingURLPolicy.local()
        let owner = TimelineService(coordinator: EventStreamSharedCaptureCoordinator.shared, root: root,
            dataHome: dataHome, defaults: .standard, resolveBundleID: { $0.bundleIdentifier },
            resolver: resolver, filter: policy.makeRecordFilter(resolver: resolver),
            loadInstructions: { try readResource("TimelineMemoryInstructions") },
            // ACUA has no model of its own, so no summary is produced; recording
            // and history still work.
            summariser: .init(tenMinute: { _ in throw TimelineSummaryError.summariesUnavailable },
                              sixHour: { _, _ in throw TimelineSummaryError.summariesUnavailable }), jitter: {
                // Default maximum summary jitter, in seconds.
                let maximum = 60.0
                return .seconds(maximum * Double(UInt64.random(in: 0...0x20000000000000)) / Double(0x20000000000000))
            }, recordTelemetry: {
                DiscardedTelemetry.drop($0)
            }, onError: { logger.error("\(String(describing: $0), privacy: .private)") })
        existing = owner
        return owner
    }

    private static func readResource(_ name: String) throws -> String {
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name + ".md")
        if let bundled = Bundle.main.url(forResource: name, withExtension: "md") {
            return try String(contentsOf: bundled, encoding: .utf8)
        }
        guard let adjacent else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: adjacent, encoding: .utf8)
    }

    static var isRunningOrPaused: Bool {
        guard let existing else { return false }
        return existing.status().state != .stopped
    }

    static func stopIfLoaded() { _ = existing?.stop(reason: .serviceTerminated) }
}

enum TimelineIPC {
    static func perform(route: TimelineOperation.Route, request: Any) throws -> JSON {
        let operation = try TimelineOperation(route: route, request: request)
        return try withOwner { try operation.execute(on: $0) }
    }

    static func statusMenu() throws -> JSON {
        try withOwner { owner in
            let applications = AppSessions.shared.activeApplications().compactMap { session -> StatusMenuState.Application? in
                guard let app = NSRunningApplication(processIdentifier: session.app.pid),
                      !app.isTerminated, AppResolver.processKey(app) == session.process,
                      let url = app.bundleURL else { return nil }
                let bundleURL = url.resolvingSymlinksInPath().standardizedFileURL
                return .init(id: bundleURL.path, name: app.localizedName ?? session.app.bundleIdentifier,
                    bundleIdentifier: session.app.bundleIdentifier, bundleURL: bundleURL.absoluteString)
            }
            let response = StatusMenuState(computerUse: .init(activeApplications: applications),
                computerHistory: owner.statusMenuHistory(now: Date(), calendar: .current))
            return try JSONEncoder().encode(response)
        }
    }

    private static func withOwner(
        _ run: @escaping @MainActor (TimelineService<EventStreamNativeRecorder>) throws -> Data
    ) throws -> JSON {
        let metadata = ComputerUseTelemetryContext.snapshot()
        let scope = RequestRuntime.workerScope()
        let execute: @MainActor () throws -> Data = {
            try ComputerUseTelemetryContext.$current.withValue(metadata) {
                try RequestRuntime.withWorkerScope(scope, cancelled: { Task.isCancelled }) {
                    try RequestRuntime.check()
                    return try run(TimelineNativeOwner.shared)
                }
            }
        }
        let data: Data
        if Thread.isMainThread {
            data = try MainActor.assumeIsolated { try execute() }
        } else {
            let pending = PendingResult<Data>(discard: { _ in })
            let task = Task { @MainActor in
                do { try Task.checkCancellation(); pending.complete(.success(try execute())) }
                catch { pending.complete(.failure(error)) }
            }
            do {
                try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
                data = try pending.take()
            } catch {
                task.cancel()
                pending.abandon()
                throw error
            }
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw ServiceError(.unknownError, "Timeline returned an invalid response")
        }
        return value
    }
}
