import Foundation

struct TimelineMemorySummaryWriter {
    let store: TimelineMemorySummaryStore
    var randomID: () -> String = {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }
    var onRemovalError: (Error) -> Void = { _ in }

    func writeSummary(_ content: String, sixHour: Bool, bucketStart: Date) throws {
        try FileManager.default.createDirectory(at: store.memoryResourcesURL, withIntermediateDirectories: true)
        let previous = try store.listSummaries(sixHour: sixHour).filter { $0.bucketStart == bucketStart }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let filename = formatter.string(from: bucketStart) + "-" + randomID() + "-" +
            (sixHour ? "6h" : "10min") + "-" + TimelineMemorySlug.make(from: content) + ".md"
        let url = store.memoryResourcesURL.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        for summary in previous where summary.url != url {
            do { try FileManager.default.removeItem(at: summary.url) }
            catch { onRemovalError(error) }
        }
    }
}
