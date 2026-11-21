import Foundation

/// The summary catalogue and deletion operations. Summary generation
/// and reading file contents belong to the separate memory pipeline.
struct TimelineSummaryFile: Equatable {
    var bucketStart: Date
    var url: URL
}

struct TimelineMemorySummaryStore {
    let memoryResourcesURL: URL

    func listSummaries(sixHour: Bool) throws -> [TimelineSummaryFile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: memoryResourcesURL.path) else { return [] }
        return try manager.contentsOfDirectory(
            at: memoryResourcesURL, includingPropertiesForKeys: nil, options: []
        ).compactMap { url in
            guard url.pathExtension == "md",
                  let start = Self.bucketStart(url: url, sixHour: sixHour) else { return nil }
            return TimelineSummaryFile(bucketStart: start, url: url)
        }.sorted {
            if $0.bucketStart == $1.bucketStart { return $0.url.path < $1.url.path }
            return $0.bucketStart < $1.bucketStart
        }
    }

    func containsSummaries(overlapping interval: DateInterval) throws -> Bool {
        for sixHour in [false, true] {
            if try listSummaries(sixHour: sixHour).contains(where: {
                overlaps($0, sixHour: sixHour, interval: interval)
            }) { return true }
        }
        return false
    }

    func removeSummaries(overlapping interval: DateInterval) throws {
        for sixHour in [false, true] {
            for summary in try listSummaries(sixHour: sixHour) {
                if overlaps(summary, sixHour: sixHour, interval: interval) {
                    try FileManager.default.removeItem(at: summary.url)
                }
            }
        }
    }

    private func overlaps(_ summary: TimelineSummaryFile, sixHour: Bool,
                          interval: DateInterval) -> Bool {
        summary.bucketStart < interval.end &&
            interval.start < summary.bucketStart.addingTimeInterval(sixHour ? 21_600 : 600)
    }

    private static func bucketStart(url: URL, sixHour: Bool) -> Date? {
        let name = url.lastPathComponent
        guard name.contains(sixHour ? "-6h-" : "-10min-") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: String(name.prefix(19)))
    }
}
