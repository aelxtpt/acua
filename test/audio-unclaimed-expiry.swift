// Golden traces cover the automatic task and the real 30-second expiry.
// Only owned callbacks and fixture files are used; no audio is captured.
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
        FileHandle.standardError.write(Data(("OWNED_AUDIO_FIXTURE_URL "+url.path+"\n").utf8))
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
    private static func automaticTask(_ session:Session)->Task<Void,Never> {
        let value=Mirror(reflecting:session.recorder).children.first(where:{$0.label=="autoStop"})!.value
        return Mirror(reflecting:value).children.first!.value as! Task<Void,Never>
    }
    private static func lifetimePhase(_ session:Session)->[String:Any] {
        var result=phase(session)
        let task=Mirror(reflecting:session.recorder).children.first(where:{$0.label=="autoStop"})!.value
        result["hasAutomaticTask"] = !Mirror(reflecting:task).children.isEmpty
        return result
    }
    private static func wait(_ condition:()->Bool,seconds:Double=2) {
        let limit=ProcessInfo.processInfo.systemUptime+seconds
        while !condition() && ProcessInfo.processInfo.systemUptime<limit {Thread.sleep(forTimeInterval:0.002)}
        precondition(condition())
    }
    static func main()throws {
        let began=ProcessInfo.processInfo.systemUptime
        var latestAutomaticStop=began
        var sessions=[Session](),items=[(String,Session,Box<Bool>)](),rows=[[String:Any]](),next=[String:Session]()
        defer {for session in sessions {try? FileManager.default.removeItem(at:session.url)}}
        for name in ["unclaimed-success","unclaimed-error","claim-before-expiry","claim-then-replace","turn-before-expiry"] {
            let instance=try make(failure:name=="unclaimed-error",duration:100);sessions.append(instance)
            let task=automaticTask(instance),done=Box(false)
            Task.detached {await task.value;done.set(true)}
            items.append((name,instance,done))
        }
        for (name,instance,done) in items {
            wait {phase(instance)["autoStopped"] as? Bool == true}
            latestAutomaticStop=ProcessInfo.processInfo.systemUptime
            let during=lifetimePhase(instance),early=done.read(),intervention:[String:Any]
            if name.hasPrefix("claim") {
                intervention=stop(instance)
                if name=="claim-then-replace" {let replacement=try replacement(instance);next[name]=replacement;sessions.append(replacement)}
            } else if name.hasPrefix("turn") {
                instance.recorder.discardEndedTurn(threadID:"owned-session",turnID:"owned-turn");intervention=["ok":true]
            } else {intervention=["none":true]}
            if !name.hasPrefix("unclaimed") {wait {done.read()}}
            rows.append(["name":name,"afterAutomaticStop":during,"loopCompletedBeforeIntervention":early,
                "intervention":intervention,"loopCompletedSoonAfterIntervention":done.read(),
                "afterIntervention":lifetimePhase(next[name] ?? instance),"oldFileExistsAfterIntervention":FileManager.default.fileExists(atPath:instance.url.path),"ownedURL":instance.url.path])
        }
        while ProcessInfo.processInfo.systemUptime<latestAutomaticStop+29 {Thread.sleep(forTimeInterval:0.025)}
        for (index,item) in items.enumerated() {
            rows[index]["beforeExpiry"]=lifetimePhase(next[item.0] ?? item.1)
            rows[index]["oldFileExistsBeforeExpiry"]=FileManager.default.fileExists(atPath:item.1.url.path)
        }
        // Observe completion rather than assuming the scheduler resumes within 1.5 seconds.
        // The recorder sleeps with an unspecified tolerance; keep the
        // pre-expiry check at 29 seconds and fail if completion misses 40 seconds.
        while ProcessInfo.processInfo.systemUptime<latestAutomaticStop+40 && !items.allSatisfy({$0.2.read()}) {Thread.sleep(forTimeInterval:0.025)}
        for (index,(name,instance,done)) in items.enumerated() {
            let observed=next[name] ?? instance
            rows[index]["afterExpiry"]=lifetimePhase(observed)
            rows[index]["loopCompletedAfterExpiry"]=done.read()
            rows[index]["oldFileExistsAfterExpiry"]=FileManager.default.fileExists(atPath:instance.url.path)
            rows[index]["claimAfterExpiry"]=stop(observed)
            rows[index]["oldStopCalls"]=instance.calls.read()
            rows[index]["newStopCalls"]=next[name]?.calls.read() ?? 0
            if let replacement=next[name] {rows[index]["newOwnedURL"]=replacement.url.path}
        }
        try JSONSerialization.data(withJSONObject:["cases":rows,"observationSeconds":ProcessInfo.processInfo.systemUptime-began,"automaticStopObservationSeconds":latestAutomaticStop-began,"observationOrigin":"latest observed automatic Stop","realAudioRecordings":0],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        precondition(AudioRecorder.unclaimedRecordingLifetime == .seconds(30))
        print("PASS unclaimed recording lifetime is 30 seconds")
        let golden=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        let expected=golden["cases"] as! [[String:Any]]
        precondition(rows.count==5 && expected.count==5)
        func normalize(_ value:Any,paths:[String:String])->Any {
            if let list=value as? [Any] {return list.map{normalize($0,paths:paths)}}
            guard let object=value as? [String:Any] else{return value}
            var result=object.filter{$0.key != "ownedURL" && $0.key != "newOwnedURL"}.mapValues{normalize($0,paths:paths)}
            if let url=result["url"] as? String,let owned=paths[url]{result["url"]=owned}
            if let error=result["error"] as? String,["invalidDuration","noActiveRecording","noDisplay","recordingAlreadyActive","recordingNotOwned"].contains(error){result.removeValue(forKey:"domain")}
            return result
        }
        for (row,expectedRow) in zip(rows,expected) {
            var paths=[row["ownedURL"] as! String:"<own output URL>"]
            if let url=row["newOwnedURL"] as? String {paths[url]="<new output URL>"}
            let actual=normalize(row,paths:paths) as! [String:Any]
            precondition(NSDictionary(dictionary:actual).isEqual(to:expectedRow),"Expiry mismatch: \(row["name"]!)\n\(actual)\n\(expectedRow)")
            print("PASS unclaimed recording expiry: \(row["name"]!)")
        }
    }
}
