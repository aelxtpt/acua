import Foundation

struct TimelineMemoryRollupWindows {
    let store: TimelineMemorySummaryStore

    func missingSixHourIntervals(now: Date) throws -> [DateInterval] {
        let summaries = try store.listSummaries(sixHour: false)
        guard !summaries.isEmpty else { return [] }
        let existing = Set(try store.listSummaries(sixHour: true).map(\.bucketStart))
        var seen = Set<Date>(), intervals = [DateInterval]()
        for summary in summaries {
            let bucket = Date(timeIntervalSince1970: floor(summary.bucketStart.timeIntervalSince1970 / 21_600) * 21_600)
            guard seen.insert(bucket).inserted, !existing.contains(bucket),
                  bucket.addingTimeInterval(21_600) <= now else { continue }
            intervals.append(DateInterval(start: bucket, duration: 21_600))
        }
        return intervals
    }
}
