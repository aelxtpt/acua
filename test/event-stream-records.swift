import Foundation

@MainActor
private final class Filter: EventStreamRecordFilter {
    var requests: [Int] = []
    var hold: Set<Int> = []
    var continuations: [Int: CheckedContinuation<EventStreamRecordDisposition, Never>] = [:]
    var decisions: [Int: EventStreamRecordDisposition] = [:]
    func disposition(for record: EventStreamRecord) async -> EventStreamRecordDisposition {
        requests.append(record.id)
        if hold.contains(record.id) { return await withCheckedContinuation { continuations[record.id] = $0 } }
        return decisions[record.id] ?? .include
    }
    func release(_ id: Int, _ disposition: EventStreamRecordDisposition = .include) {
        continuations.removeValue(forKey: id)!.resume(returning: disposition)
    }
}

@MainActor
private final class Writer: EventStreamRecordWriting {
    var records: [EventStreamRecord] = []
    var failedIDs: Set<Int> = []
    func append(_ record: EventStreamRecord) throws {
        if failedIDs.contains(record.id) { throw CocoaError(.fileWriteOutOfSpace) }
        records.append(record)
    }
    var ids: [Int] { records.map(\.id) }
}

@main
struct EventStreamRecordTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < end else { fatalError("Async record test timed out") }
            await Task.yield()
        }
    }
    static func record(_ id: Int, app: String? = "A", url: String? = nil, kind: EventStreamEventKind = .mouseClick) -> EventStreamRecord {
        EventStreamRecord(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(id)), kind: kind,
            app: app.map { .init(name: $0, secureInput: false, bundleIdentifier: "local." + $0) },
            window: .init(url: url))
    }
    static func observed(_ app: EventStreamApp) -> EventStreamObservedApplication? {
        guard let name = app.name, !name.isEmpty else { return nil }
        return .init(id: app.bundleIdentifier ?? name, name: name, bundleIdentifier: app.bundleIdentifier, bundleURL: nil, executableURL: nil)
    }

    @MainActor static func main() async throws {
        let blocked = EventStreamBlockedCaptureContext(application: observed(.init(name:"A",secureInput:false,bundleIdentifier:"local.A"))!, normalizedURL: URL(string:"https://blocked.test/path")!)
        let writer = Writer(), filter = Filter()
        let processor = EventStreamRecordProcessor(writer: writer, filter: filter, resolveApplication: observed)
        var blockedNotifications: [EventStreamBlockedCaptureContext?] = []
        var observedNotifications: [[String]] = []
        processor.onBlockedContextChange = { blockedNotifications.append($0) }
        processor.onObservedApplicationsChange = { observedNotifications.append($0.map(\.id)) }
        processor.receive(record(1))
        check("URL-less record commits synchronously when queue is idle", writer.ids == [1] && !processor.isProcessing && filter.requests.isEmpty)
        check("first committed app is observed", processor.observedApplications.map(\.id) == ["local.A"] && observedNotifications == [["local.A"]])
        processor.receive(record(2,app:"B"))
        processor.receive(record(3,app:"A"))
        check("observed apps move to MRU front by identity", processor.observedApplications.map(\.id) == ["local.A","local.B"] && observedNotifications.count == 3)
        var changed = record(4);changed.app?.name="New A name"
        processor.receive(changed)
        check("already-front identity keeps old metadata and emits no duplicate notice", processor.observedApplications.first?.name == "A" && observedNotifications.count == 3)
        processor.receive(record(5,app:"B"))
        processor.receive(changed)
        check("moving an older identity to front refreshes its metadata", processor.observedApplications.first?.name == "New A name" && observedNotifications.count == 5)
        processor.updateBlockedCaptureContext(blocked)
        processor.updateBlockedCaptureContext(blocked)
        check("equal blocked context does not emit duplicate notification", blockedNotifications.count == 1)
        processor.receive(record(6,app:nil,kind:.sessionStarted))
        check("app-less boundary preserves current blocked state", processor.blockedCaptureContext == blocked && blockedNotifications.count == 1)
        processor.receive(record(7), isSuppressed:true)
        check("suppressed include clears policy state without writing or observing app", processor.blockedCaptureContext == nil && blockedNotifications.count == 2 && !writer.ids.contains(7) && observedNotifications.count == 5)

        let orderedWriter=Writer(), orderedFilter=Filter()
        orderedFilter.hold=[10]
        let ordered=EventStreamRecordProcessor(writer:orderedWriter,filter:orderedFilter,resolveApplication:observed)
        ordered.receive(record(10,url:"https://allowed.test/"))
        await until {orderedFilter.continuations[10] != nil}
        ordered.receive(record(11,url:nil))
        ordered.receive(record(12,url:""))
        check("records without URLs wait behind an outstanding policy", orderedWriter.ids.isEmpty && ordered.pendingCount == 2 && orderedFilter.requests == [10])
        let batch=ordered.processingTask!
        orderedFilter.release(10)
        await batch.value
        check("queued decisions and writes retain arrival order", orderedFilter.requests == [10,11,12] && orderedWriter.ids == [10,11,12])
        check("empty queue releases its worker", !ordered.isProcessing && ordered.pendingCount == 0)
        orderedFilter.hold=[13]
        ordered.receive(record(13,url:"https://allowed.test/"))
        await until {orderedFilter.continuations[13] != nil}
        ordered.receive(record(14,app:nil,kind:.sessionEnded))
        check("session boundary bypasses queued policy immediately", orderedWriter.ids == [10,11,12,14] && orderedFilter.requests == [10,11,12,13])
        let beforeStop=ordered.processingTask!
        ordered.cancelPendingRecords();orderedFilter.release(13)
        await beforeStop.value
        check("late policy result after stop cannot append record", orderedWriter.ids == [10,11,12,14] && ordered.pendingCount == 0 && !ordered.isProcessing)

        let cancellationWriter=Writer(), cancellationFilter=Filter()
        cancellationFilter.hold=[20,22]
        let cancellation=EventStreamRecordProcessor(writer:cancellationWriter,filter:cancellationFilter,resolveApplication:observed)
        cancellation.receive(record(20,url:"https://old.test/"))
        await until {cancellationFilter.continuations[20] != nil}
        cancellation.receive(record(21,url:"https://discard.test/"))
        let oldTask=cancellation.processingTask!
        cancellation.cancelPendingRecords()
        check("cancel discards queue and detaches worker immediately", cancellation.pendingCount == 0 && !cancellation.isProcessing)
        cancellation.receive(record(22,url:"https://new.test/"))
        await until {cancellationFilter.continuations[22] != nil}
        let newTask=cancellation.processingTask!
        cancellationFilter.release(20,.blocked(blocked))
        await oldTask.value
        check("old cancelled worker cannot clear new worker or mutate policy state", cancellation.isProcessing && cancellation.blockedCaptureContext == nil && cancellationWriter.ids.isEmpty)
        cancellationFilter.release(22)
        await newTask.value
        check("new worker survives late old completion", cancellationWriter.ids == [22] && cancellationFilter.requests == [20,22] && !cancellation.isProcessing)
        cancellation.receive(record(23,url:"https://not-started.test/"))
        let notStarted=cancellation.processingTask!
        cancellation.cancelPendingRecords();await notStarted.value
        check("cancellation before worker starts avoids policy entirely", !cancellationFilter.requests.contains(23))

        let suppressedWriter=Writer(), suppressedFilter=Filter()
        suppressedFilter.decisions[30] = .blocked(blocked)
        let suppressed=EventStreamRecordProcessor(writer:suppressedWriter,filter:suppressedFilter,resolveApplication:observed)
        suppressed.receive(record(30,url:"https://blocked.test/"),isSuppressed:true)
        await suppressed.processingTask!.value
        check("suppressed blocked record updates policy state but never persists", suppressed.blockedCaptureContext == blocked && suppressedWriter.ids.isEmpty && suppressed.observedApplications.isEmpty)
        suppressed.receive(record(31,app:nil))
        check("app-less include leaves blocked policy context intact", suppressed.blockedCaptureContext == blocked && suppressedWriter.ids == [31])
        suppressed.receive(record(32,url:"https://allowed.test/"),isSuppressed:true)
        await suppressed.processingTask!.value
        check("suppressed allowed URL clears context but does not persist or observe", suppressed.blockedCaptureContext == nil && suppressedWriter.ids == [31] && suppressed.observedApplications.isEmpty)
        suppressed.updateBlockedCaptureContext(blocked);suppressed.cancelPendingRecords()
        check("cancel alone does not invent policy-state reset", suppressed.blockedCaptureContext == blocked)

        let absentFilter=Filter()
        let absent=EventStreamRecordProcessor(writer:nil,filter:absentFilter,resolveApplication:observed)
        absent.receive(record(40,url:"https://ignored.test/"))
        check("missing writer discards before queue, filter or app observation", !absent.isProcessing && absent.pendingCount == 0 && absentFilter.requests.isEmpty && absent.observedApplications.isEmpty)
        let disappearingWriter=Writer(), disappearingFilter=Filter()
        disappearingFilter.hold=[41]
        let disappearing=EventStreamRecordProcessor(writer:disappearingWriter,filter:disappearingFilter,resolveApplication:observed)
        disappearing.receive(record(41,url:"https://allowed.test/"))
        await until {disappearingFilter.continuations[41] != nil}
        let disappearingTask=disappearing.processingTask!
        disappearing.writer=nil
        disappearingFilter.release(41);await disappearingTask.value
        check("writer absence during commit writes nothing but preserves original app observation", disappearingWriter.ids.isEmpty && disappearing.observedApplications.count == 1)

        let faultyWriter=Writer(), faultyFilter=Filter()
        faultyWriter.failedIDs=[50]
        var writeErrors=0
        let faulty=EventStreamRecordProcessor(writer:faultyWriter,filter:faultyFilter,resolveApplication:observed,onWriteError:{_ in writeErrors += 1})
        faulty.receive(record(50,app:"Failed"))
        faulty.receive(record(51,app:"Later"))
        check("write failure reports error, skips app observation and permits later records", writeErrors == 1 && faultyWriter.ids == [51] && faulty.observedApplications.map(\.name) == ["Later"])
        var unresolvable=record(52);unresolvable.app?.name=nil
        faulty.receive(unresolvable)
        check("unresolvable app does not prevent successful event write", faultyWriter.ids == [51,52] && faulty.observedApplications.map(\.name) == ["Later"])

        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("cua-event-records-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:temp)}
        let jsonl=try EventStreamJSONLWriter(sessionID:"session",rootDirectoryURL:temp)
        let nativeFilter=EventStreamURLPolicyRecordFilter(isURLBlocked:{$0.host == "blocked.test"},isWebBrowser:{_ in true},resolveApplication:observed)
        let persisted=EventStreamRecordProcessor(writer:jsonl,filter:nativeFilter,resolveApplication:observed)
        persisted.receive(record(60,app:nil,kind:.sessionStarted))
        persisted.receive(record(61,url:"https://allowed.test/"))
        persisted.receive(record(62,url:"https://blocked.test/private?synthetic=secret"))
        persisted.receive(record(63,url:"https://allowed.test/"),isSuppressed:true)
        await persisted.processingTask!.value
        persisted.receive(record(64,app:nil,kind:.sessionEnded))
        jsonl.close()
        let data=try Data(contentsOf:jsonl.eventsURL)
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let written=try String(decoding:data,as:UTF8.self).split(separator:"\n").map{try decoder.decode(EventStreamRecord.self,from:Data($0.utf8))}
        check("real filter and JSONL writer persist only allowed nonsuppressed records", written.map(\.id) == [60,61,64])
        check("blocked URL contents are absent from the actual file", !String(decoding:data,as:UTF8.self).contains("synthetic=secret"))
        check("suppressed-events file is not fabricated by the processor", try! FileManager.default.contentsOfDirectory(atPath:jsonl.directoryURL.path) == ["events.jsonl"])

        let stressWriter=Writer(), stressFilter=Filter()
        let stress=EventStreamRecordProcessor(writer:stressWriter,filter:stressFilter,resolveApplication:observed)
        for id in 1000..<2000 {stress.receive(record(id,url:"https://allowed.test/"))}
        await stress.processingTask!.value
        check("thousand-record batch loses no records and preserves order", stressWriter.ids == Array(1000..<2000) && stressFilter.requests == Array(1000..<2000) && !stress.isProcessing)
        print("EVENT STREAM RECORD PROCESSING: \(checks) checks passed")
    }
}
