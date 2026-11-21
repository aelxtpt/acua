import Foundation
import Darwin

struct TimelineSummaryChild: Equatable {
    let filename: String
    let contents: String
}

// Keep all seven native metadata fields in the key. Segment ID alone does not
// coalesce requests whose counts, paths, timestamps, or end reasons differ.
private struct SummaryTaskKey: Hashable {
    let id: String
    let eventsPath: String
    let startedAt: Date
    let endedAt: Date?
    let endReason: String?
    let eventCount: Int?
    let suppressedEventCount: Int?
    init(_ metadata: EventStreamMetadata) {
        id = metadata.id; eventsPath = metadata.eventsPath
        startedAt = metadata.startedAt; endedAt = metadata.endedAt
        endReason = metadata.endReason?.rawValue
        eventCount = metadata.eventCount; suppressedEventCount = metadata.suppressedEventCount
    }
}

@MainActor final class TimelineMemoryPipeline {
    struct Summariser {
        var tenMinute: (EventStreamMetadata) async throws -> String
        var sixHour: (DateInterval, [TimelineSummaryChild]) async throws -> String
    }
    enum Level: String { case tenMinute = "ten_minute", sixHour = "six_hour" }
    enum Result: String { case succeeded, failed, cancelled }

    private let store: TimelineMemorySummaryStore
    private let writer: TimelineMemorySummaryWriter
    private let summariser: Summariser
    private let sleep: (Duration) async throws -> Void
    private let delay: () -> Duration
    private let now: () -> Date
    private let finished: (Level, Result, TimeInterval) -> Void
    private let onError: (Error) -> Void
    private let defaultDuration: TimeInterval
    private var tenMinuteTasks = [SummaryTaskKey: Task<Void, Never>]()
    private var sixHourTasks = [DateInterval: Task<Void, Never>]()

    init(store: TimelineMemorySummaryStore, summariser: Summariser,
         defaultDuration: TimeInterval = 600,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         delay: @escaping () -> Duration = {
             // Draw an integer in 0...2^53, then scale by the configured
             // jitter maximum. The default maximum is 60s.
             .seconds(60 * Double(UInt64.random(in: 0...0x20000000000000)) / Double(0x20000000000000))
         }, now: @escaping () -> Date = Date.init,
         finished: @escaping (Level, Result, TimeInterval) -> Void = { _, _, _ in },
         onError: @escaping (Error) -> Void = { _ in }) {
        self.store = store; self.writer = .init(store: store, onRemovalError: onError)
        self.summariser = summariser; self.defaultDuration = defaultDuration
        self.sleep = sleep; self.delay = delay; self.now = now
        self.finished = finished; self.onError = onError
    }

    var taskCounts: [Int] { [tenMinuteTasks.count, sixHourTasks.count] }

    func recoverLatestSegment(_ metadata: EventStreamMetadata) throws {
        guard try !store.listSummaries(sixHour: false).contains(where: { $0.bucketStart == metadata.startedAt }) else { return }
        enqueue(metadata)
    }

    func enqueue(_ metadata: EventStreamMetadata) {
        let key = SummaryTaskKey(metadata)
        guard tenMinuteTasks[key] == nil else { return }
        tenMinuteTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateTenMinute(metadata, key: key)
        }
    }

    func cancel(overlapping interval: DateInterval) {
        for (key, task) in tenMinuteTasks {
            let end = max(key.startedAt, key.endedAt ?? key.startedAt.addingTimeInterval(defaultDuration))
            if overlaps(DateInterval(start: key.startedAt, end: end), interval) { task.cancel() }
        }
        for (window, task) in sixHourTasks where overlaps(window, interval) { task.cancel() }
        // Cleanup belongs to the running task, including already-cancelled work.
    }

    private func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private func generateTenMinute(_ metadata: EventStreamMetadata, key: SummaryTaskKey) async {
        defer { tenMinuteTasks.removeValue(forKey: key) }
        var started: Date?
        do {
            if let count = metadata.eventCount {
                guard count > 0 else { return }
            } else {
                let values = try URL(filePath: metadata.eventsPath).resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size > 0 else { return }
            }
            try await sleep(delay())
            try Task.checkCancellation()
            let generationStart = now()
            started = generationStart
            let content = try await summariser.tenMinute(metadata)
            try Task.checkCancellation()
            try writer.writeSummary(content, sixHour: false, bucketStart: metadata.startedAt)
            finished(.tenMinute, .succeeded, max(0, now().timeIntervalSince(generationStart)))
            let end = max(metadata.startedAt, metadata.endedAt ?? metadata.startedAt.addingTimeInterval(defaultDuration))
            do {
                for interval in try TimelineMemoryRollupWindows(store: store).missingSixHourIntervals(now: end) {
                    enqueueSixHour(interval)
                }
            } catch { onError(error) }
        } catch {
            if !(error is CancellationError) { onError(error) }
            if let started {
                finished(.tenMinute, error is CancellationError ? .cancelled : .failed, max(0, now().timeIntervalSince(started)))
            }
        }
    }

    private func enqueueSixHour(_ interval: DateInterval) {
        guard sixHourTasks[interval] == nil else { return }
        sixHourTasks[interval] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateSixHour(interval)
        }
    }

    private func generateSixHour(_ interval: DateInterval) async {
        defer { sixHourTasks.removeValue(forKey: interval) }
        let started = now()
        do {
            try Task.checkCancellation()
            var seen = Set<Date>()
            let children = try store.listSummaries(sixHour: false).filter {
                seen.insert($0.bucketStart).inserted &&
                    floor($0.bucketStart.timeIntervalSince1970 / 21_600) * 21_600 == interval.start.timeIntervalSince1970
            }
            guard !children.isEmpty,
                  try !store.listSummaries(sixHour: true).contains(where: { $0.bucketStart == interval.start }) else { return }
            try Task.checkCancellation()
            let values = try readChildren(children)
            let content = try await summariser.sixHour(interval, values)
            try Task.checkCancellation()
            try writer.writeSummary(content, sixHour: true, bucketStart: interval.start)
            finished(.sixHour, .succeeded, max(0, now().timeIntervalSince(started)))
        } catch {
            if !(error is CancellationError) { onError(error) }
            finished(.sixHour, error is CancellationError ? .cancelled : .failed, max(0, now().timeIntervalSince(started)))
        }
    }

    private func readChildren(_ children: [TimelineSummaryFile]) throws -> [TimelineSummaryChild] {
        let fd = open(store.memoryResourcesURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TimelineSummaryError.invalidSummaryDirectory }
        defer { close(fd) }
        let reader = TimelineSummaryReader()
        return try children.map { child in
            let result = try reader.read(child, directoryFD: fd)
            return .init(filename: result.filename, contents: result.contents)
        }
    }
}
