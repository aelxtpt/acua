import Foundation

struct TimelineSegmentState {
    var id:String
    var eventsURL:URL
    var metadataURL:URL
    var startedAt:Date
    var eventCount:Int?
    var suppressedEventCount:Int?

    // Unreadable/undecodable metadata creates a new segment state.
    // A restored file can point at a different events file and retain nil counts.
    static func load(segmentsURL:URL,startedAt:Date)->Self {
        let formatter=ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        let id=formatter.string(from:startedAt).replacingOccurrences(of:":",with:"-").replacingOccurrences(of:".",with:"-")
        let directory=segmentsURL.appendingPathComponent(id,isDirectory:true)
        let metadataURL=directory.appendingPathComponent("metadata.json")
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        if let data=try? Data(contentsOf:metadataURL),let metadata=try? decoder.decode(EventStreamMetadata.self,from:data) {
            return .init(id:metadata.id,eventsURL:URL(fileURLWithPath:metadata.eventsPath),metadataURL:metadataURL,
                startedAt:metadata.startedAt,eventCount:metadata.eventCount,suppressedEventCount:metadata.suppressedEventCount)
        }
        return .init(id:id,eventsURL:directory.appendingPathComponent("events.jsonl"),metadataURL:metadataURL,
            startedAt:startedAt,eventCount:0,suppressedEventCount:0)
    }
}

// Writes Timeline segments: initialization, append, rotation, finish and
// clear-history. All access is serialized by the owning Timeline service.
final class TimelineSegmentWriter {
    let segmentStore:TimelineSegmentStore
    private(set) var currentSegment:TimelineSegmentState
    private(set) var segmentFileHandle:FileHandle?
    var suppressedFileHandle:FileHandle?
    let suppressedEventsURL:URL?=nil

    init(store:TimelineSegmentStore,now:Date)throws {
        segmentStore=store
        try FileManager.default.createDirectory(at:store.segmentsURL,withIntermediateDirectories:true)
        let duration=store.segmentDurationSeconds
        let start=Date(timeIntervalSince1970:duration*floor(now.timeIntervalSince1970/duration))
        currentSegment = .load(segmentsURL:store.segmentsURL,startedAt:start)
        try store.prune(now:now,keeping:[currentSegment.eventsURL.deletingLastPathComponent()])
        try open(currentSegment)
    }

    private func open(_ state:TimelineSegmentState)throws {
        try FileManager.default.createDirectory(at:state.metadataURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        if !FileManager.default.fileExists(atPath:state.eventsURL.path) {
            FileManager.default.createFile(atPath:state.eventsURL.path,contents:nil)
        }
        let handle=try FileHandle(forWritingTo:state.eventsURL)
        segmentFileHandle=handle
        try handle.seekToEnd()
        // The open document omits end/count fields even if restored
        // in-memory counts exist. Never recount the previous events file.
        try EventStreamMetadataStorage.write(.init(id:state.id,eventsPath:state.eventsURL.path,startedAt:state.startedAt),to:state.metadataURL)
    }

    private func closedMetadata(endingAt date:Date)->EventStreamMetadata {
        .init(id:currentSegment.id,eventsPath:currentSegment.eventsURL.path,startedAt:currentSegment.startedAt,
            endedAt:date,eventCount:currentSegment.eventCount,suppressedEventCount:currentSegment.suppressedEventCount)
    }

    // Rotate forward only, closing at the nominal boundary. The old
    // and new directories survive retention until the caller handles the result.
    func rotateIfNeeded(at date:Date)throws->EventStreamMetadata? {
        let duration=segmentStore.segmentDurationSeconds
        let start=Date(timeIntervalSince1970:duration*floor(date.timeIntervalSince1970/duration))
        guard start>currentSegment.startedAt else{return nil}
        let old=currentSegment
        let metadata=closedMetadata(endingAt:old.startedAt.addingTimeInterval(duration))
        try EventStreamMetadataStorage.write(metadata,to:old.metadataURL)
        // Retain the closed handle until open replaces it, including on failure.
        try segmentFileHandle?.close()
        currentSegment = .load(segmentsURL:segmentStore.segmentsURL,startedAt:start)
        try segmentStore.prune(now:date,keeping:[old.eventsURL.deletingLastPathComponent(),currentSegment.eventsURL.deletingLastPathComponent()])
        try open(currentSegment)
        return metadata
    }

    // Rotation precedes the write. A failed write keeps any
    // rotation effects but does not increment the counter or return metadata.
    func append(_ record:EventStreamRecord)throws->EventStreamMetadata? {
        let rotated=try rotateIfNeeded(at:record.timestamp)
        if let handle=segmentFileHandle {
            let encoder=JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            try handle.write(contentsOf:encoder.encode(record))
            try handle.write(contentsOf:Data([0x0A]))
        }
        if let count=currentSegment.eventCount {currentSegment.eventCount=count+1}
        return rotated
    }

    // Suppressed events still rotate/count when no
    // suppressed handle exists. A write failure leaves that count unchanged.
    func appendSuppressed(_ record:EventStreamRecord)throws->EventStreamMetadata? {
        let rotated=try rotateIfNeeded(at:record.timestamp)
        if let handle=suppressedFileHandle {
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            try handle.write(contentsOf:encoder.encode(record));try handle.write(contentsOf:Data([0x0A]))
        }
        if let count=currentSegment.suppressedEventCount{currentSegment.suppressedEventCount=count+1}
        return rotated
    }

    // Finishing is nonthrowing. Empty known counters do nothing; unknown counts
    // still produce metadata. Persistence failure does not erase the result.
    func finish(now:Date=Date())->EventStreamMetadata? {
        guard currentSegment.eventCount != 0 || currentSegment.suppressedEventCount != 0 else{return nil}
        let metadata=closedMetadata(endingAt:now)
        try? EventStreamMetadataStorage.write(metadata,to:currentSegment.metadataURL)
        return metadata
    }

    // Reload the slot, then prune and reopen. State is assigned
    // before I/O; an opening failure leaves that state visible to the owner.
    private func reload(at date:Date)throws {
        let duration=segmentStore.segmentDurationSeconds
        let start=Date(timeIntervalSince1970:duration*floor(date.timeIntervalSince1970/duration))
        currentSegment = .load(segmentsURL:segmentStore.segmentsURL,startedAt:start)
        try segmentStore.prune(now:date,keeping:[currentSegment.eventsURL.deletingLastPathComponent()])
        try open(currentSegment)
    }

    // A failed operation triggers one recovery attempt. A recovery
    // failure replaces the initial error; a successful recovery preserves it.
    func clearHistory(overlapping interval:DateInterval,now:Date)throws->[DateInterval] {
        do {
            try segmentFileHandle?.close()
            segmentFileHandle=nil
            let removed=try segmentStore.removeSegments(overlapping:interval)
            try reload(at:now)
            return removed
        }catch {
            let originalError=error
            try? segmentFileHandle?.close()
            segmentFileHandle=nil
            try reload(at:now)
            throw originalError
        }
    }

    func close() {
        try? segmentFileHandle?.close();segmentFileHandle=nil
        try? suppressedFileHandle?.close();suppressedFileHandle=nil
    }
    deinit {close()}
}
