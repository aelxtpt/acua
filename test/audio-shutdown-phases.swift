import Foundation

// Recorder phase traces with controlled owned callbacks.
// See staging/audio-shutdown-phases/comparison.json; no audio is recorded.

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
    private static func make(failure: Bool = false, hold: Bool = false, duration: Int = 300_000, as caller: AudioRecorder.Owner? = nil) throws -> Session {
        let factory=Factory(failure:failure,hold:hold)
        let recorder=AudioRecorder(startCapture:factory.open)
        try recorder.start(.init(maxDurationMilliseconds: duration), owner: caller ?? owner)
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
            let url = try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+150]) {
                try session.recorder.stop(owner: caller ?? owner)
            }
            return ["url": url.path, "exists": FileManager.default.fileExists(atPath: url.path)]
        } catch {
            return ["error": String(describing: error), "domain": (error as NSError).domain, "code": (error as NSError).code]
        }
    }
    private static func phase(_ session:Session)->[String:Any] {
        var result=current(session)
        let recording=Mirror(reflecting:session.recorder).children.first(where:{$0.label=="recording"})!.value
        let value=Mirror(reflecting:recording).children.first?.value
        let auto=value.flatMap {Mirror(reflecting:$0).children.first(where:{$0.label=="didAutoStop"})?.value as? Bool} ?? false
        result["autoStopped"]=auto
        result["fileExists"]=FileManager.default.fileExists(atPath:session.url.path)
        return result
    }
    private static func awaitAutomatic(_ session:Session,waitingForExit:Bool=false)->DispatchSemaphore {
        let value=Mirror(reflecting:session.recorder).children.first(where:{$0.label=="autoStop"})!.value
        let task=Mirror(reflecting:value).children.first!.value as! Task<Void,Never>
        let done=DispatchSemaphore(value:0)
        Task.detached {
            if waitingForExit {await task.value}
            else {
                let limit=ContinuousClock.now.advanced(by:.seconds(2))
                while phase(session)["autoStopped"] as? Bool != true && ContinuousClock.now<limit {
                    try? await Task.sleep(for:.milliseconds(2))
                }
                precondition(phase(session)["autoStopped"] as? Bool == true)
            }
            done.signal()
        }
        return done
    }
    static func main() throws {
        var rows=[[String:Any]](),sessions=[Session]()
        defer {for session in sessions {try? FileManager.default.removeItem(at:session.url)}}
        for fail in [false,true] {
            let instance=try make(failure:fail,duration:100);sessions.append(instance)
            let done=awaitAutomatic(instance)
            precondition(done.wait(timeout:.now()+3) == .success)
            let state=phase(instance),calls=instance.calls.read(),claimed=stop(instance)
            rows.append(["name":fail ? "auto-error":"auto-success","afterPhase":state,
                "stopCallsBeforeClaim":calls,"claim":claimed,"nativeStopCalls":instance.calls.read(),"ownedURL":instance.url.path])
        }
        let owners:[(String,AudioRecorder.Owner,String,String?)]=[
            ("turn-match",owner,"owned-session","owned-turn"),
            ("turn-wrong-thread",owner,"other","owned-turn"),
            ("turn-wrong-turn",owner,"owned-session","other"),
            ("turn-thread-only",owner,"owned-session",nil),
            ("turn-owner-no-turn",.init(sessionID:"owned-session",senderPID:123),"owned-session","owned-turn"),
            ("turn-owner-no-session",.init(sessionID:nil,senderPID:123),"owned-session","owned-turn")]
        for (name,caller,thread,turn) in owners {
            let instance=try make(as:caller);sessions.append(instance)
            instance.recorder.discardEndedTurn(threadID:thread,turnID:turn)
            let state=phase(instance),calls=instance.calls.read(),claimed=stop(instance,as:caller)
            rows.append(["name":name,"afterPhase":state,"stopCallsBeforeClaim":calls,
                "claim":claimed,"nativeStopCalls":instance.calls.read(),"ownedURL":instance.url.path])
        }
        for discard in [false,true] {for fail in [false,true] {
            let name=(discard ? "turn-pending":"auto-pending")+(fail ? "-error":"-success")
            let old=try make(failure:fail,hold:true,duration:discard ? 300_000:100);sessions.append(old)
            let done:DispatchSemaphore
            if discard {
                done=DispatchSemaphore(value:0)
                DispatchQueue.global().async {
                    old.recorder.discardEndedTurn(threadID:"owned-session",turnID:"owned-turn");done.signal()
                }
            } else {done=awaitAutomatic(old,waitingForExit:true)}
            precondition(old.entered.wait(timeout:.now()+3) == .success)
            let during=phase(old),other=stop(old)
            var next:Session?,startError:String?
            do {
                try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+150]) {
                    next=try replacement(old)
                }
                sessions.append(next!)
            } catch {startError=String(describing:error)}
            old.gate.open()
            precondition(done.wait(timeout:.now()+3) == .success)
            let after=phase(next ?? old),claimed=stop(next ?? old)
            var row:[String:Any]=["name":name,"duringPhase":during,"other":other,"afterFirstCompletion":after,
                "claim":claimed,"oldStopCalls":old.calls.read(),"newStopCalls":next?.calls.read() ?? 0,"ownedURL":old.url.path]
            if let next {row["newOwnedURL"]=next.url.path}
            if let startError {row["startError"]=startError}
            rows.append(row)
        }}
        try JSONSerialization.data(withJSONObject:["cases":rows,"realAudioRecordings":0],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        let golden=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        let expected=golden["cases"] as! [[String:Any]]
        precondition(expected.count==12 && rows.count==12)
        func normalize(_ value:Any,paths:[String:String])->Any {
            if let list=value as? [Any] {return list.map {normalize($0,paths:paths)}}
            guard let object=value as? [String:Any] else {return value}
            var result=object.filter {$0.key != "ownedURL" && $0.key != "newOwnedURL"}.mapValues {normalize($0,paths:paths)}
            if let url=result["url"] as? String,let owned=paths[url] {result["url"]=owned}
            if let error=result["error"] as? String,["noActiveRecording","recordingNotOwned","recordingAlreadyActive"].contains(error) {
                result.removeValue(forKey:"domain")
            }
            return result
        }
        for (row,expectedRow) in zip(rows,expected) {
            var paths=[row["ownedURL"] as! String:"<own output URL>"]
            if let next=row["newOwnedURL"] as? String {paths[next]="<new output URL>"}
            let actual=normalize(row,paths:paths) as! [String:Any]
            precondition(NSDictionary(dictionary:actual).isEqual(to:expectedRow),"Audio phase mismatch: \(row["name"]!)\n\(actual)\n\(expectedRow)")
            print("PASS audio shutdown phase: \(row["name"]!)")
        }
    }
}
