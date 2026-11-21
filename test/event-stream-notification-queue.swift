import Foundation

@MainActor private final class Sleeper {
    var delays: [Duration] = []
    var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    func sleep(_ duration: Duration) async throws {
        let index = delays.count; delays.append(duration)
        try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, error: Error? = nil) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

@main struct Tests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), "FAIL: \(label)"); checks += 1; print("PASS: \(label)")
        }
        // Drain actor jobs without relying on elapsed wall-clock timing.
        func drain() async { for _ in 0..<20 { await Task.yield() } }
        let clock = Sleeper()
        var recording = true, emitted: [EventStreamRecord] = []
        var duringEmit: ((EventStreamRecord) -> Void)?
        let queue = EventStreamAXNotificationQueue(isRecording: { recording }, sleep: { try await clock.sleep($0) }, emit: { record in
            emitted.append(record); duringEmit?(record)
        })
        func record(_ id: Int) -> EventStreamRecord {
            .init(id: id, timestamp: Date(timeIntervalSince1970: Double(id)), kind: .selectionChanged,
                  app: .init(name: "App", secureInput: false, processIdentifier: 1),
                  window: .init(title: "Window", windowID: 2),
                  selection: .init(selectedText: "selection \(id)", selectedItems: []))
        }
        queue.enqueue(record(1), key: "text", notification: "AXSelectedTextChanged")
        await drain()
        check("text selection schedules 500 millisecond delay", clock.delays == [.milliseconds(500)] && queue.pendingCount == 1 && emitted.isEmpty)
        queue.enqueue(record(2), key: "text", notification: "AXSelectedTextChanged")
        await drain()
        check("same key replaces pending payload and task", queue.pendingCount == 1 && queue.scheduledCount == 1 && clock.delays.count == 2)
        clock.finish(0); await drain()
        check("cancelled old delay cannot emit replacement", emitted.isEmpty && queue.pendingCount == 1)
        clock.finish(1); await drain()
        check("latest complete payload survives coalescing", emitted == [record(2)])
        check("successful emission removes pending record and timer", queue.pendingCount == 0 && queue.scheduledCount == 0)
        queue.enqueue(record(3), key: "rows", notification: "AXSelectedRowsChanged")
        await drain()
        queue.enqueue(record(4), key: "cells", notification: "AXSelectedCellsChanged")
        await drain()
        check("different keys schedule independently at 250 milliseconds", clock.delays.suffix(2).allSatisfy { $0 == .milliseconds(250) } && queue.pendingCount == 2)
        clock.finish(3); await drain()
        check("one key firing leaves other key pending", emitted.last?.id == 4 && queue.pendingCount == 1)
        clock.finish(2); await drain()
        check("independent notifications preserve their payload and identities", emitted.map(\.id) == [2,4,3])
        queue.enqueue(record(5), key: "flush", notification: "AXSelectedTextChanged"); await drain()
        queue.flushPendingRecords()
        check("explicit flush emits before deadline", emitted.last?.id == 5 && queue.pendingCount == 0 && queue.scheduledCount == 0)
        clock.finish(4); await drain()
        check("flushed delay cannot emit a duplicate", emitted.map(\.id) == [2,4,3,5])
        queue.enqueue(record(6), key: "cancel", notification: "AXSelectedTextChanged"); await drain()
        queue.cancelPendingRecords()
        check("cancellation discards records and timer owners", queue.pendingCount == 0 && queue.scheduledCount == 0 && emitted.count == 4)
        clock.finish(5); await drain()
        check("late cancelled task does not deliver", emitted.count == 4)
        queue.enqueue(record(7), key: "stopped", notification: "AXSelectedTextChanged"); await drain()
        recording = false; clock.finish(6); await drain()
        check("recording guard prevents delayed delivery", emitted.count == 4 && queue.pendingCount == 1)
        queue.flushPendingRecords()
        check("inactive explicit flush leaves pending state", queue.pendingCount == 1 && emitted.count == 4)
        recording = true; queue.flushPendingRecords()
        check("owner can resume and explicitly flush pending record", emitted.last?.id == 7 && queue.scheduledCount == 0)
        enum Failure: Error { case clock }
        queue.enqueue(record(8), key: "clock-error", notification: "AXSelectedRowsChanged"); await drain()
        clock.finish(7, error: Failure.clock); await drain()
        check("non-cancellation sleep error still runs guarded flush", emitted.last?.id == 8 && queue.pendingCount == 0)
        queue.enqueue(record(9), key: "reentrant", notification: "AXSelectedRowsChanged"); await drain()
        duringEmit = { value in
            if value.id == 9 { queue.enqueue(record(10), key: "reentrant", notification: "AXSelectedRowsChanged") }
        }
        queue.flushPendingRecords(); await drain()
        check("record is removed before callback can reuse same key", emitted.last?.id == 9 && queue.pendingCount == 1 && queue.scheduledCount == 1)
        duringEmit = nil
        clock.finish(8); await drain()
        check("old reentrant task cannot consume new same-key record", emitted.last?.id == 9 && queue.pendingCount == 1)
        clock.finish(9); await drain()
        check("new same-key record receives its own delay and emission", emitted.last?.id == 10 && queue.pendingCount == 0)
        queue.enqueue(record(11), key: "a", notification: "AXSelectedRowsChanged")
        queue.enqueue(record(12), key: "b", notification: "AXSelectedRowsChanged"); await drain()
        queue.flushPendingRecords()
        check("bulk flush emits each snapshotted key once", Set(emitted.suffix(2).map(\.id)) == [11,12] && queue.pendingCount == 0)
        clock.finish(10); clock.finish(11); await drain()
        queue.cancelPendingRecords(); queue.cancelPendingRecords()
        check("repeated cleanup is inert", queue.pendingCount == 0 && queue.scheduledCount == 0 && clock.continuations.isEmpty)
        print("\(checks) checks")
    }
}
