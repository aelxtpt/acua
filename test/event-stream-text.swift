import Foundation

@MainActor
private final class Sleeper {
    var waits: [(Duration, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
    }
    func resume(_ index: Int, error: Error? = nil) {
        if let error { waits[index].1.resume(throwing: error) }
        else { waits[index].1.resume() }
    }
}

@main
struct EventStreamTextTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ result: @autoclosure () -> Bool) {
        guard result() else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Timed out") }
            await Task.yield()
        }
    }
    @MainActor static func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        typealias Recorder = EventStreamTextInputRecorder<Int>
        let sleeper = Sleeper()
        var count = 0, captures = 0, refreshes = 0, resolutions = 0
        var active = true
        var records: [EventStreamRecord] = []
        var descriptor = EventStreamAXElement(role: "AXTextField", value: "updated")
        let a = EventStreamEventTarget(identity: .init(processIdentifier: 100, windowID: 10),
            app: .init(name: "Initial", secureInput: false), window: .init(title: "Initial"))
        let b = EventStreamEventTarget(identity: .init(processIdentifier: 100, windowID: 11))
        let c = EventStreamEventTarget(identity: .init(processIdentifier: 101, windowID: 11))
        let nilIDs = EventStreamEventTarget(identity: .init())
        var resolve: (EventStreamEventTarget?) -> (EventStreamApp?, EventStreamWindow?) = {
            ($0?.app, $0?.window)
        }
        var onEmit: ((EventStreamRecord) -> Void)?
        let recorder = Recorder(nextIdentity: {
            count += 1
            return .init(id: count, timestamp: Date(timeIntervalSince1970: Double(count)))
        }, refreshTarget: { _ in refreshes += 1; return descriptor },
        resolveContext: { resolutions += 1; return resolve($0) },
        isRecording: { active }, sleep: sleeper.sleep, emit: { records.append($0); onEmit?($0) })
        let capture: () -> Recorder.CapturedTarget = {
            captures += 1
            return .init(description: .init(role: "AXTextField", value: "old"), element: 1)
        }
        recorder.append("", target: a, captureTarget: capture)
        check("empty input allocates neither target nor identity", count == 0 && captures == 0)
        recorder.flush()
        check("empty flush emits nothing and performs no context lookup", records.isEmpty && resolutions == 0)
        recorder.append("Olá 👩🏽‍💻", target: a, captureTarget: capture)
        await until { sleeper.waits.count == 1 }
        check("native debounce is 750 milliseconds", sleeper.waits[0].0 == .milliseconds(750))
        recorder.append(" e\u{301}", target: a, captureTarget: capture)
        await until { sleeper.waits.count == 2 }
        check("same process and window coalesce without recapturing AX target", captures == 1 && count == 2 && records.isEmpty)
        sleeper.resume(0)
        await settle()
        check("replaced timer cannot flush newer text even when sleep ignores cancellation", records.isEmpty)
        sleeper.resume(1)
        await until { records.count == 1 }
        check("Unicode text retains exact scalars", records[0].keyboard?.text == "Olá 👩🏽‍💻 e\u{301}")
        check("flush gets fresh identity and timestamp after per-key allocations", records[0].id == 3 && records[0].timestamp == Date(timeIntervalSince1970: 3) && count == 3)
        check("AX target refresh replaces cached descriptor at flush", refreshes == 1 && records[0].keyboard?.target?.value == "updated")
        check("text event has keyboardTextInput kind and empty modifiers", records[0].kind == .keyboardTextInput && records[0].keyboard?.modifiers == [] && records[0].keyboard?.keyEquivalent == nil && records[0].mouse == nil)
        check("initial context is supplied to required resolver", records[0].app?.name == "Initial" && records[0].window?.title == "Initial")

        recorder.append("one", target: a, captureTarget: capture)
        recorder.append("two", target: b, captureTarget: capture)
        check("window change flushes previous text before buffering next", records.count == 2 && records.last?.keyboard?.text == "one" && recorder.text == "two")
        recorder.append("three", target: c, captureTarget: capture)
        check("process change splits identical window identifiers", records.count == 3 && records.last?.keyboard?.text == "two" && recorder.text == "three")
        recorder.discard()
        recorder.append("n", target: nilIDs, captureTarget: capture)
        recorder.append("il", target: nilIDs, captureTarget: capture)
        recorder.flush()
        check("two optional-nil target identities coalesce", records.last?.keyboard?.text == "nil")
        await until { sleeper.waits.count >= 3 }
        // Tasks cancelled before they start can still enter injected sleep;
        // release all held continuations to check late completion safely.
        await settle()
        let oldWaitCount = sleeper.waits.count
        for i in 2..<oldWaitCount { sleeper.resume(i) }
        await settle()
        check("explicit flush/discard prevents stale debounce emission", records.count == 4)

        for field in 0..<6 {
            var sensitive = EventStreamAXElement()
            switch field {
            case 0: sensitive.role = "AXSecureTextField"
            case 1: sensitive.subrole = "AXSecureTextField"
            case 2: sensitive.title = "PASSWORD"
            case 3: sensitive.description = "secure entry"
            case 4: sensitive.placeholder = "password here"
            default: sensitive.identifier = "my_secure_id"
            }
            check("sensitive marker in descriptor field \(field) is detected", Recorder.isSensitive(sensitive))
        }
        check("value is excluded from the sensitive-target heuristic", !Recorder.isSensitive(.init(value: "password secure")))
        check("absent descriptor is not sensitive", !Recorder.isSensitive(nil))
        descriptor = .init(subrole: "AXSecureTextField", value: "synthetic fixture value")
        recorder.append("synthetic typed text", target: a, captureTarget: capture)
        recorder.flush()
        check("fresh secure descriptor suppresses keyboard text", records.last?.keyboard?.text == nil && records.last?.keyboard?.target?.subrole == "AXSecureTextField")
        check("text helper keeps the captured descriptor without adding AX redaction", records.last?.keyboard?.target?.value == "synthetic fixture value")
        recorder.append("cached", target: a, captureTarget: { .init(description: .init(title: "cached target"), element: nil) })
        recorder.flush()
        check("missing native target retains cached descriptor", records.last?.keyboard?.text == "cached" && records.last?.keyboard?.target?.title == "cached target")
        resolve = { _ in (.init(name: "Refreshed", secureInput: false), .init(title: "Fresh window")) }
        recorder.append("context", target: a, captureTarget: { .init() })
        recorder.flush()
        check("output context resolves at flush instead of reusing event snapshot", records.last?.app?.name == "Refreshed" && records.last?.window?.title == "Fresh window")

        let beforeReentry = records.count
        onEmit = { _ in
            onEmit = nil
            recorder.append("reentrant", target: a, captureTarget: { .init() })
        }
        recorder.append("outer", target: a, captureTarget: { .init() })
        recorder.flush()
        check("reentrant emission starts a buffer without previous text", records.count == beforeReentry + 1 && recorder.text == "reentrant")
        recorder.flush()
        check("reentrant buffer remains flushable", records.last?.keyboard?.text == "reentrant")
        await settle()
        let outstanding = sleeper.waits.count
        for i in oldWaitCount..<outstanding { sleeper.resume(i) }
        await settle()

        let beforeStopped = records.count
        recorder.append("stopped", target: a, captureTarget: { .init() })
        await until { sleeper.waits.count == outstanding + 1 }
        active = false
        sleeper.resume(outstanding)
        await settle()
        check("timer checks recording state after sleep", records.count == beforeStopped && recorder.text == "stopped")
        recorder.discard(); active = true
        recorder.append("sleep error", target: a, captureTarget: { .init() })
        await until { sleeper.waits.count == outstanding + 2 }
        sleeper.resume(outstanding + 1, error: CocoaError(.userCancelled))
        await settle()
        check("noncancellation sleep error still flushes buffer", records.count == beforeStopped + 1 && records.last?.keyboard?.text == "sleep error" && recorder.text.isEmpty)
        recorder.discard()

        // Actual clock, filter, processor, JSONL encoding and decoding together.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cua-text-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try EventStreamJSONLWriter(sessionID: "test", rootDirectoryURL: temp)
        let filter = EventStreamURLPolicyRecordFilter(isURLBlocked: { $0.host == "blocked.test" }, isWebBrowser: { _ in true }, resolveApplication: {
            .init(id: "test", name: $0.name ?? "", bundleIdentifier: nil, bundleURL: nil, executableURL: nil)
        })
        let processor = EventStreamRecordProcessor(writer: writer, filter: filter, resolveApplication: { _ in nil })
        var realCount = 0, emitted = 0
        let real = Recorder(nextIdentity: { realCount += 1; return .init(id: realCount, timestamp: Date()) },
            refreshTarget: { _ in .init() }, resolveContext: { ($0?.app, $0?.window) }, isRecording: { true },
            emit: { emitted += 1; processor.receive($0) })
        let start = ContinuousClock.now
        real.append("persisted text", target: a, captureTarget: { .init() })
        await until { emitted == 1 }
        check("real continuous clock waits for native debounce interval", ContinuousClock.now - start >= .milliseconds(740))
        real.append("blocked synthetic text", target: .init(identity: a.identity, app: a.app, window: .init(url: "https://blocked.test/")), captureTarget: { .init() })
        real.flush()
        await processor.processingTask?.value
        writer.close()
        let data = try Data(contentsOf: writer.eventsURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try decoder.decode(EventStreamRecord.self, from: Data($0.utf8))
        }
        check("real text-to-policy-to-JSONL pipeline persists only allowed input", decoded.count == 1 && decoded[0].keyboard?.text == "persisted text" && !String(decoding: data, as: UTF8.self).contains("blocked synthetic text"))
        print("EVENT STREAM TEXT: \(checks) checks passed")
    }
}
