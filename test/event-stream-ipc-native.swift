import AppKit
import ApplicationServices
import Foundation

@MainActor private final class FactoryCalls { var count = 0 }
private final class ExpirationResult: @unchecked Sendable {
    private let result = PendingResult<Bool>(discard: { _ in })
    var signal: DispatchSemaphore { result.signal }
    func complete(_ value: Bool) { result.complete(.success(value)) }
    func take() throws -> Bool { try result.take() }
}
@main @MainActor enum Tests {
    static var checks = 0
    static func check(_ name: String, _ valid: Bool) { precondition(valid,name);checks += 1;print("PASS: \(name)") }
    static func pump() { CFRunLoopRunInMode(.defaultMode,0.005,false) }
    static func blockMain(_ seconds: Double) { Thread.sleep(forTimeInterval:seconds) }
    static func until(_ name: String, _ valid: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(12)
        while !valid() {
            precondition(ContinuousClock.now<end,name)
            pump()
            try await Task.sleep(for:.milliseconds(15))
        }
    }
    static func fixtureEvents(_ directory: URL) -> [JSON] {
        (try? String(contentsOf:directory.appendingPathComponent("events.jsonl"),encoding:.utf8))?.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? JSON} ?? []
    }
    static func command(_ value: String, _ directory: URL, response: String) async throws -> JSON {
        let count=fixtureEvents(directory).count
        try value.write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        var result:JSON?
        try await until("Fixture command \(value)") {result=fixtureEvents(directory).dropFirst(count).first{$0["event"] as? String==response};return result != nil}
        return result!
    }
    static func editor(_ app: AXUIElement) -> AXUIElement? {
        var pending=[app],index=0
        while index<pending.count && index<500 {
            let value=pending[index];index += 1
            if AX.copy(value,"AXIdentifier") as? String=="input-editor" {return value}
            pending.append(contentsOf:AX.children(value))
        }
        return nil
    }
    static func call(_ kind: String, _ request: Any, owner: EventStreamRecordingOwner, metadata: JSON? = nil) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let data=try ComputerUseTelemetryContext.validatedWireData(metadata)
                    let result=try ComputerUseTelemetryContext.withAgentTurnMetadata(data) {
                        try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().addingTimeInterval(15).timeIntervalSince1970*1000]) {
                            try EventStreamIPC.perform(requestType:"ComputerUseIPCEventStream\(kind)Request",request:request,owner:{owner})
                        }
                    }
                    continuation.resume(returning:result)
                }catch{continuation.resume(throwing:error)}
            }
        }
    }
    static func records(_ path: String) -> [EventStreamRecord] {
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        return (try? String(contentsOfFile:path,encoding:.utf8))?.split(separator:"\n").compactMap{try? decoder.decode(EventStreamRecord.self,from:Data($0.utf8))} ?? []
    }
    static func same(_ a: JSON, _ b: JSON) -> Bool {NSDictionary(dictionary:a).isEqual(to:b)}

    static func main() async throws {
        setbuf(stdout,nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard !Permissions.screenLocked(),AXIsProcessTrusted(),CGPreflightScreenCaptureAccess() else {fputs("Native recording IPC needs an unlocked permitted desktop.\n",stderr);exit(2)}
        if CommandLine.arguments.contains("--preflight"){return}
        let args=CommandLine.arguments
        guard args.count==4,let pid=Int32(args[1]),let window=UInt32(args[2]),let app=NSRunningApplication(processIdentifier:pid),app.bundleIdentifier=="test.acua.event-stream-producer-fixture" else {fatalError("Owned recording fixture required")}
        let directory=URL(fileURLWithPath:args[3]),root=directory.appendingPathComponent("recordings")
        _=app.activate(options:[]);_ = try await command("request-key-focus",directory,response:"requested-key-focus")
        try await until("Owned app foreground") {NSWorkspace.shared.frontmostApplication?.processIdentifier==pid}
        guard let editor=editor(AXUIElementCreateApplication(pid))else{fatalError("Owned editor required")}
        let recorder=EventStreamNativeRecorderFactory.make(prefetchConfiguration:{[:]})
        let coordinator=EventStreamCaptureCoordinator(recorder:recorder)
        let owner=EventStreamRecordingOwner(coordinator:coordinator,rootDirectoryURL:root,shouldCaptureApplication:{$0.processIdentifier==pid})
        defer{_ = owner.service.stop(reason:.serviceTerminated)}
        let initial=try await call("Status",true,owner:owner)
        check("status accepts the empty request decoder's scalar input",initial["isRecording"] as? Bool==false && initial["maxDurationSeconds"] as? Int==1800)
        check("status does not start native capture or create storage",!recorder.isRecording && coordinator.subscriptionCount==0 && !FileManager.default.fileExists(atPath:root.path))
        for request:Any in [[:],NSNull(),["reason":true],["reason":"unknown"]] {
            do {_ = try await call("Stop",request,owner:owner);fatalError("Malformed stop accepted")}
            catch let error as ServiceError {check("malformed stop fails before capture",error.code == .couldNotGetRequestData && !recorder.isRecording)}
        }
        let started=try await call("Start",NSNull(),owner:owner,metadata:["session_id":"owned-thread","turn_id":"owned-turn"])
        guard let session=started["sessionID"] as? String,let events=started["eventsPath"] as? String,let metaPath=started["metadataPath"] as? String else{fatalError("Native storage paths missing")}
        check("start on a socket-style thread activates the real native recorder",started["isRecording"] as? Bool==true && recorder.isRecording && coordinator.subscriptionCount==1)
        check("recording owner retains the actual telemetry session ID",owner.service.originatingThreadID=="owned-thread" && session != "owned-thread")
        check("wire dates use the numeric reference-epoch strategy",started["startedAt"] is NSNumber && started["startedAt"] as? Double != nil)
        let repeated=try await call("Start",["ignored":true],owner:owner,metadata:["session_id":"different"])
        check("repeated start preserves the session and originating conversation",same(started,repeated) && owner.service.originatingThreadID=="owned-thread" && coordinator.subscriptionCount==1)
        try await until("Real AX window reaches the recording file") {records(events).contains{$0.kind == .windowChanged && $0.app?.processIdentifier==pid && $0.window?.windowID==window && $0.ax?.text.isEmpty==false}}
        check("native producer records are actually persisted as JSONL",records(events).first?.kind == .sessionStarted && records(events).contains{$0.ax?.text.isEmpty==false})
        var range=CFRange(location:0,length:2)
        check("owned Unicode selection is applied through AX",AXUIElementSetAttributeValue(editor,"AXSelectedTextRange" as CFString,AXValueCreate(.cfRange,&range)!) == .success)
        try await until("Native selected emoji persisted") {records(events).contains{$0.kind == .selectionChanged && $0.selection?.selectedText=="🙂"}}
        check("IPC-started session retains the default native observer payload",records(events).contains{$0.kind == .selectionChanged && $0.selection?.selectedRange == .init(location:0,length:2)})
        range=CFRange(location:0,length:0);_ = AXUIElementSetAttributeValue(editor,"AXSelectedTextRange" as CFString,AXValueCreate(.cfRange,&range)!)
        _ = try await command("event-stream-text",directory,response:"event-stream-text-posted")
        try await until("Native Unicode input persisted") {records(events).contains{$0.kind == .keyboardTextInput && $0.keyboard?.text=="á😀"}}
        check("IPC-started session records real Unicode input with its native owner",records(events).contains{$0.kind == .keyboardTextInput && $0.app?.processIdentifier==pid && $0.window?.windowID==window})
        check("fixture capture predicate excludes unrelated applications",records(events).allSatisfy{$0.app?.processIdentifier==nil || $0.app?.processIdentifier==pid})
        let stopped=try await call("Stop",["reason":"tool_stopped"],owner:owner)
        check("stop removes the subscription and native input observer",stopped["isRecording"] as? Bool==false && !recorder.isRecording && coordinator.subscriptionCount==0)
        check("stop persists the session boundary and its end reason",records(events).last?.kind == .sessionEnded && stopped["endReason"] as? String=="tool_stopped")
        let stored=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:metaPath))) as! JSON
        check("file metadata uses ISO dates while IPC retains numeric dates",stored["startedAt"] is String && stopped["endedAt"] is NSNumber && stored["endReason"] as? String=="tool_stopped")
        let before=try Data(contentsOf:URL(fileURLWithPath:events))
        let duplicate=try await call("Stop",["reason":"recording_controls_cancelled"],owner:owner)
        let afterDuplicate=try Data(contentsOf:URL(fileURLWithPath:events))
        check("inactive stop preserves completed files and status",same(duplicate,stopped) && afterDuplicate==before)
        let cancelled=try await call("Start",[:],owner:owner,metadata:["session_id":"next-thread"])
        let cancelledPath=cancelled["eventsPath"] as! String
        check("restart allocates a new real session directory",cancelled["sessionID"] as? String != session && owner.service.originatingThreadID=="next-thread")
        _ = try await call("Stop",["reason":"recording_controls_cancelled"],owner:owner)
        check("recording-controls cancellation truncates the actual events file",try Data(contentsOf:URL(fileURLWithPath:cancelledPath)).isEmpty)
        let second=EventStreamRecordingOwner(coordinator:coordinator,rootDirectoryURL:directory.appendingPathComponent("second-recordings"),shouldCaptureApplication:{$0.processIdentifier==pid})
        _ = try await call("Start",[:],owner:owner);_ = try await call("Start",[:],owner:second)
        check("two recording owners share the single native capture coordinator",coordinator.subscriptionCount==2 && recorder.isRecording)
        _ = try await call("Stop",["reason":"tool_stopped"],owner:owner)
        check("stopping one sink leaves the other native subscription running",coordinator.subscriptionCount==1 && recorder.isRecording && second.service.isRecording)
        let terminated=try await call("Stop",["reason":"service_terminated"],owner:second)
        check("last native sink stops with service termination semantics",coordinator.subscriptionCount==0 && !recorder.isRecording && terminated["endReason"] as? String=="service_terminated")
        EventStreamStorageConfiguration.configure(appGroupContainerURL:nil)
        let unavailable=EventStreamRecordingOwner(coordinator:coordinator,shouldCaptureApplication:{$0.processIdentifier==pid})
        do {_ = try await call("Start",[:],owner:unavailable);fatalError("Unavailable storage accepted")}
        catch EventStreamRecordingStorageError.unavailable {check("missing native container fails before starting capture",!recorder.isRecording && coordinator.subscriptionCount==0 && unavailable.service.status().startedAt==nil)}
        let timer=EventStreamRecordingOwner(coordinator:coordinator,rootDirectoryURL:directory.appendingPathComponent("timed-recordings"),maximumDurationSeconds:1,shouldCaptureApplication:{$0.processIdentifier==pid})
        _ = try await call("Start",[:],owner:timer)
        try await until("Native recording automatically stops") {!timer.service.isRecording}
        check("automatic maximum duration stops the real subscription",timer.service.status().endReason == .maxDuration && coordinator.subscriptionCount==0 && !recorder.isRecording)
        let calls=FactoryCalls(),announced=DispatchSemaphore(value:0),expired=ExpirationResult()
        Thread.detachNewThread {
            do {
                try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().addingTimeInterval(0.2).timeIntervalSince1970*1000]) {
                    announced.signal()
                    _ = try EventStreamIPC.perform(requestType:"ComputerUseIPCEventStreamStartRequest",request:JSON(),owner:{calls.count += 1;return owner})
                }
                expired.complete(false)
            }catch let error as ServiceError{expired.complete(error.code == .unknownError && error.message.contains("deadline"))}
            catch{expired.complete(false)}
        }
        precondition(announced.wait(timeout:.now()+2) == .success,"Background deadline fixture did not enter")
        blockMain(0.5)
        precondition(expired.signal.wait(timeout:.now()+2) == .success,"Expired call remained blocked on the main actor")
        check("queued start reports its deadline while main actor is occupied",try expired.take())
        try await Task.sleep(for:.milliseconds(60));pump()
        check("expired queued start cannot create a late native recording",calls.count==0 && !owner.service.isRecording && coordinator.subscriptionCount==0 && !recorder.isRecording)
        print("\(checks) native event-stream IPC and storage checks passed; artifacts: \(directory.path)")
    }
}
