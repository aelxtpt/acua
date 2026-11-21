import Foundation

// Golden traces of the recorder actor with owned fake SCStream callbacks.
// This tests actor state and callback ordering without recording system audio.

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
}
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
    func open() {
        lock.lock(); opened = true; let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume()
    }
}
private final class Resource {}
private final class Stream: @unchecked Sendable {
    let url: URL
    let failure: Bool
    let hold: Bool
    let calls = Box(0)
    let entered = DispatchSemaphore(value: 0)
    let gate = Gate()
    weak var resource: Resource?
    init(url: URL, failure: Bool, hold: Bool) { self.url=url;self.failure=failure;self.hold=hold }
    func stop() async throws {
        calls.set(calls.read()+1);entered.signal()
        if hold { await gate.wait() }
        if failure { throw NSError(domain:"OwnedAudioStop",code:41) }
    }
}
private final class Factory: @unchecked Sendable {
    let failure: Bool
    let hold: Bool
    let streams = Box([Stream]())
    init(failure: Bool,hold: Bool) {self.failure=failure;self.hold=hold}
    func open(_ url: URL) throws -> (() throws -> Void) {
        let first=streams.read().isEmpty
        let stream=Stream(url:url,failure:first && failure,hold:first && hold)
        streams.set(streams.read()+[stream])
        try Data("owned fixture, no audio samples".utf8).write(to:url)
        let resource=Resource();stream.resource=resource
        let bridge=try AudioCaptureBridge.start(begin:{resource},finish:{_ in try await stream.stop()})
        return {try bridge.stop()}
    }
}
private struct Session: @unchecked Sendable {
    let recorder: AudioRecorder
    let factory: Factory
    let stream: Stream
    var url: URL {stream.url}
    var calls: Box<Int> {stream.calls}
    var entered: DispatchSemaphore {stream.entered}
    var gate: Gate {stream.gate}
}

@main enum AudioReentrancyTests {
    private static let owner = AudioRecorder.Owner(sessionID: "owned-session", senderPID: 123, turnID: "owned-turn")
    private static func make(failure: Bool = false, hold: Bool = false) throws -> Session {
        let factory=Factory(failure:failure,hold:hold)
        let recorder=AudioRecorder(startCapture:factory.open)
        try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: owner)
        return Session(recorder:recorder,factory:factory,stream:factory.streams.read().last!)
    }
    private static func replacement(_ old:Session) throws -> Session {
        try old.recorder.start(.init(maxDurationMilliseconds:300_000),owner:owner)
        return Session(recorder:old.recorder,factory:old.factory,stream:old.factory.streams.read().last!)
    }
    private static func current(_ instance:Session) -> [String:Any] {
        let fields=Mirror(reflecting:instance.recorder).children
        let recording=fields.first(where:{$0.label=="recording"})!.value
        let value=Mirror(reflecting:recording).children.first?.value
        let url=value.flatMap {Mirror(reflecting:$0).children.first(where:{$0.label=="url"})?.value as? URL}
        let stored=fields.first(where:{$0.label=="finishCapture"})!.value
        let hasResource = !Mirror(reflecting:stored).children.isEmpty && instance.stream.resource != nil
        return ["hasURL":url != nil,"matchesNewURL":url==instance.url,"retainsNewResource":hasResource]
    }
    private static func stop(_ session: Session, as caller: AudioRecorder.Owner? = nil) -> [String: Any] {
        do {
            let url = try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+5000]) {
                try session.recorder.stop(owner: caller ?? owner)
            }
            return ["url": url.path, "exists": FileManager.default.fileExists(atPath: url.path)]
        } catch {
            return ["error": String(describing: error), "domain": (error as NSError).domain, "code": (error as NSError).code]
        }
    }
    static func main() throws {
        var rows: [[String: Any]] = [], sessions: [Session] = []
        defer { for session in sessions { try? FileManager.default.removeItem(at: session.url) } }
        func append(_ name: String, _ session: Session, _ caller: AudioRecorder.Owner? = nil) {
            rows.append(["name": name, "result": stop(session, as: caller), "nativeStopCalls": session.calls.read(), "ownedURL": session.url.path])
        }
        let simple = try make(); sessions.append(simple)
        append("success", simple); append("already-claimed", simple)
        let same = try make(); sessions.append(same)
        append("same-session-other-pid", same, .init(sessionID: "owned-session", senderPID: 999))
        let rejected = try make(); sessions.append(rejected)
        append("different-session", rejected, .init(sessionID: "other", senderPID: 123))
        append("correct-owner-after-rejection", rejected)
        let failure = try make(failure: true); sessions.append(failure)
        append("native-stop-error", failure); append("retry-after-error", failure)
        let pending = try make(hold: true); sessions.append(pending)
        let first = Box<[String: Any]?>(nil), second = Box<[String: Any]?>(nil)
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { first.set(stop(pending)); firstDone.signal() }
        precondition(pending.entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async { second.set(stop(pending)); secondDone.signal() }
        Thread.sleep(forTimeInterval: 0.15)
        let early = second.read() != nil
        pending.gate.open()
        precondition(firstDone.wait(timeout: .now() + 2) == .success)
        precondition(secondDone.wait(timeout: .now() + 2) == .success)
        rows.append(["name": "overlapping-stop", "first": first.read()!, "second": second.read()!,
            "secondReturnedBeforeFirstCallback": early, "nativeStopCalls": pending.calls.read(), "ownedURL": pending.url.path])
        for fail in [false,true] {
            let name=fail ? "overlap-error":"overlap-success"
            let old=try make(failure:fail,hold:true);sessions.append(old)
            let first=Box<[String:Any]?>(nil),done=DispatchSemaphore(value:0)
            DispatchQueue.global().async {first.set(stop(old));done.signal()}
            precondition(old.entered.wait(timeout:.now()+2) == .success)
            let second=stop(old)
            let next=try replacement(old);sessions.append(next)
            let before=current(next)
            old.gate.open();precondition(done.wait(timeout:.now()+2) == .success)
            let after=current(next),third=stop(next)
            rows.append(["name":name,"first":first.read()!,"second":second,"afterReplacement":before,
                "afterFirstCompletion":after,"third":third,"oldStopCalls":old.calls.read(),"newStopCalls":next.calls.read(),
                "ownedURL":old.url.path,"newOwnedURL":next.url.path])
        }
        for wrongOwner in [false,true] {
            let name=wrongOwner ? "wrong-owner-during-stop":"start-during-stop"
            let old=try make(hold:true);sessions.append(old)
            let first=Box<[String:Any]?>(nil),done=DispatchSemaphore(value:0)
            DispatchQueue.global().async {first.set(stop(old));done.signal()}
            precondition(old.entered.wait(timeout:.now()+2) == .success)
            let other:[String:Any]
            if wrongOwner {other=stop(old,as:.init(sessionID:"other",senderPID:123))}
            else {
                do {
                    try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+5000]) {
                        try old.recorder.start(.init(maxDurationMilliseconds:300_000),owner:owner)
                    }
                    other=["unexpectedSuccess":true]
                }
                catch {other=["error":String(describing:error),"domain":(error as NSError).domain,"code":(error as NSError).code]}
            }
            old.gate.open();precondition(done.wait(timeout:.now()+2) == .success)
            rows.append(["name":name,"first":first.read()!,"other":other,"nativeStopCalls":old.calls.read(),"ownedURL":old.url.path])
        }
        try JSONSerialization.data(withJSONObject: ["cases": rows, "realAudioRecordings": 0], options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        let expected = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        let expectedRows = expected["cases"] as! [[String:Any]]
        precondition(expectedRows.count==rows.count && rows.count==12)
        func normalize(_ value:Any,paths:[String:String])->Any {
            if let array=value as? [Any] {return array.map {normalize($0,paths:paths)}}
            guard let object=value as? [String:Any] else {return value}
            var normalized=object.filter {$0.key != "ownedURL" && $0.key != "newOwnedURL"}.mapValues {normalize($0,paths:paths)}
            if let url=normalized["url"] as? String,let owned=paths[url] {normalized["url"]=owned}
            if let error=normalized["error"] as? String,["noActiveRecording","recordingNotOwned","recordingAlreadyActive"].contains(error) {
                normalized.removeValue(forKey:"domain") // Private Swift type/context name only.
            }
            return normalized
        }
        for (row,expectedRow) in zip(rows,expectedRows) {
            var paths=[row["ownedURL"] as! String:"<own output URL>"]
            if let next=row["newOwnedURL"] as? String {paths[next]="<new output URL>"}
            let actual=normalize(row,paths:paths) as! [String:Any]
            precondition(NSDictionary(dictionary:actual).isEqual(to:expectedRow),"Audio reentrancy mismatch: \(row["name"]!)\n\(actual)\n\(expectedRow)")
            print("PASS audio reentrancy: \(row["name"]!)")
        }
    }
}
