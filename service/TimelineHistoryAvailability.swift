import Foundation

enum TimelineHistoryAvailability {
    static func canClearHistory(
        _ scope: TimelineValidatedHistoryScope, isPaused: Bool,
        now: Date, calendar: Calendar, segmentStore: TimelineSegmentStore?,
        memoryStore: TimelineMemorySummaryStore, onError: (Error) -> Void
    ) -> Bool {
        if case .applicationSession = scope, isPaused { return false }
        let interval = scope.resolvedInterval(now: now, calendar: calendar)
        do {
            if let segmentStore, try segmentStore.containsSegments(overlapping: interval) {
                return true
            }
            return try memoryStore.containsSummaries(overlapping: interval)
        } catch {
            onError(error)
            return false
        }
    }
}
