import Foundation

// Timeline segment directories on disk. This is the actual filesystem store; the native session/writer owner is composed separately.
struct TimelineSegmentStore {
    let rootDirectoryURL: URL
    var segmentDurationSeconds: TimeInterval = 600
    var segmentsURL: URL { rootDirectoryURL.appendingPathComponent("segments", isDirectory: true) }

    func segmentDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: segmentsURL,
            includingPropertiesForKeys: nil).filter(\.hasDirectoryPath)
    }

    private func metadata(in directory: URL) throws -> EventStreamMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EventStreamMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
    }

    func latestCompletedSegment(now: Date) throws -> EventStreamMetadata? {
        guard FileManager.default.fileExists(atPath: segmentsURL.path),
              let directory = try segmentDirectories().max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return nil }
        let value = try metadata(in: directory)
        let end = value.startedAt.addingTimeInterval(segmentDurationSeconds)
        guard end <= now, end > now.addingTimeInterval(-172800),
              FileManager.default.fileExists(atPath: value.eventsPath) else { return nil }
        return value
    }

    private func recordedInterval(_ metadata: EventStreamMetadata) -> DateInterval {
        let end = metadata.endedAt ?? metadata.startedAt.addingTimeInterval(segmentDurationSeconds)
        return DateInterval(start: metadata.startedAt, end: max(end, metadata.startedAt))
    }

    private func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    func containsSegments(overlapping interval: DateInterval) throws -> Bool {
        guard FileManager.default.fileExists(atPath: segmentsURL.path) else { return false }
        for directory in try segmentDirectories() {
            if overlaps(recordedInterval(try metadata(in: directory)), interval) { return true }
        }
        return false
    }

    @discardableResult
    func removeSegments(overlapping interval: DateInterval) throws -> [DateInterval] {
        guard FileManager.default.fileExists(atPath: segmentsURL.path) else { return [] }
        var removed: [DateInterval] = []
        for directory in try segmentDirectories() {
            let recorded = recordedInterval(try metadata(in: directory))
            if overlaps(recorded, interval) {
                try FileManager.default.removeItem(at: directory)
                removed.append(recorded)
            }
        }
        return removed
    }

    func prune(now: Date, keeping directories: [URL] = []) throws {
        guard FileManager.default.fileExists(atPath: segmentsURL.path) else { return }
        let keep = Set(directories.map { $0.standardizedFileURL.path })
        let cutoff = now.addingTimeInterval(-172800)
        for directory in try segmentDirectories() {
            guard !keep.contains(directory.standardizedFileURL.path),
                  let value = try? metadata(in: directory) else { continue }
            // Retention uses the segment's nominal end, irrespective of endedAt.
            if value.startedAt.addingTimeInterval(segmentDurationSeconds) <= cutoff {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }
}
