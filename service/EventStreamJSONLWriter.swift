import Foundation

// The writer is MainActor isolated. Callers must serialize access.
final class EventStreamJSONLWriter {
    let sessionID: String
    let directoryURL: URL
    let eventsURL: URL
    // Part of the layout, but no writer path assigns it after
    // initialization. Do not create a suppressed-events file.
    let suppressedEventsURL: URL? = nil
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?

    init(sessionID: String, rootDirectoryURL: URL) throws {
        self.sessionID = sessionID
        directoryURL = rootDirectoryURL.appendingPathComponent(sessionID, isDirectory: true)
        eventsURL = directoryURL.appendingPathComponent("events.jsonl", isDirectory: false)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: eventsURL.path) {
            // createFile's Bool is ignored; opening the handle reports the actual
            // filesystem error if creation failed.
            manager.createFile(atPath: eventsURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: eventsURL)
        do { try handle.seekToEnd() }
        catch { try? handle.close(); throw error }
        fileHandle = handle
    }

    func append(_ record: EventStreamRecord) throws {
        guard let fileHandle else { return }
        let data = try encoder.encode(record)
        try fileHandle.write(contentsOf: data)
        try fileHandle.write(contentsOf: Data([0x0A]))
    }

    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    deinit { close() }
}

enum EventStreamMetadataStorage {
    // ISO dates, three formatting options, atomic write.
    // The service sets both counts to nil rather than synthesizing totals.
    static func write(_ metadata: EventStreamMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }
}
