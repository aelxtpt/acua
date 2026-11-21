import AppKit
import Foundation

private final class IngressFixtureWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServicePermissionResult = .pending
    private var events = [[String: Any]]()
    private var powers = [String]()
    var outcome: ServicePermissionResult { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    var inputs: [[String: Any]] { lock.withLock { events } }
    var powerEvents: [String] { lock.withLock { powers } }
    func power(_ value: String) { lock.withLock { powers.append(value) } }
    @MainActor func ensure(_ source: ServicePermissionSource, _ id: String?) async -> ServicePermissionResult {
        let metadata = ComputerUseTelemetryContext.snapshot()
        return lock.withLock {
            events.append(["source":Int(source.rawValue),"id":id as Any? ?? NSNull(),"session":metadata.agentSessionID as Any? ?? NSNull(),"turn":metadata.agentTurnID as Any? ?? NSNull()]);return stored
        }
    }
    func install() {
        // This inherited fixture owns permission results. Policy effects are
        //explicitly isolated now that they correctly precede those results.
        Dispatch.checkApplicationPolicy = { _ in }; Dispatch.checkGlobalConfiguration = {}
        Dispatch.requestActivity = .init(provider:.init(create:{ kind,id in
            id = kind == .remoteUserActivity ? 11 : 12;self.power("acquire:\(id)");return 0
        },release:{ self.power("release:\($0)");return 0 }))
        Dispatch.ensureSystemPermissions = { source,id in
            try ServicePermissionRequestBridge(environment:.init(isMainThread:{Thread.isMainThread},wait:{try RequestRuntime.wait(for:$0,maximumSeconds:120)},ensure:{ await self.ensure($0,$1) })).check(source:source,appshotRequestID:id)
        }
    }
}
private struct IngressWireResult: Sendable { let code: Int?; let message: String?; let data: Data?; let otherError: Bool }
@MainActor enum NativePermissionIngressBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        var cases = [[String: Any]]()
        func check(_ name: String, _ value: Bool) { cases.append(["name":name,"passed":value]);if !value { print("FAIL: "+name) } }
        let previousHook=Dispatch.ensureSystemPermissions,previousActivity=Dispatch.requestActivity
        defer { Dispatch.ensureSystemPermissions=previousHook;Dispatch.requestActivity=previousActivity }
        let fixture=IngressFixtureWorld();fixture.install()
        let metadata=Data(#"{"session_id":"owned-native-ingress","turn_id":"","user_input_requested_during_turn":false}"#.utf8)
        func request(_ name: String,_ raw: String) async -> IngressWireResult {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos:.userInitiated).async {
                    do {
                        let data=try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:name,request:Data(raw.utf8),metadata:metadata,files:[],senderContext:.init(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[]),cancelled:{false})
                        continuation.resume(returning:.init(code:nil,message:nil,data:data,otherError:false))
                    } catch let error as ServiceError { continuation.resume(returning:.init(code:error.code.rawValue,message:error.message,data:nil,otherError:false)) }
                    catch { continuation.resume(returning:.init(code:nil,message:nil,data:nil,otherError:true)) }
                }
            }
        }
        let routes:[(String,UInt8,String)]=[
            ("ComputerUseIPCAppStartRequest",0,#"{"app":"local.cua.never-resolved"}"#),
            ("ComputerUseIPCAppModifyRequest",0,#"{"app":"local.cua.never-resolved","modification":{"deactivate":{}}}"#),
            ("ComputerUseIPCAppPerformActionRequest",0,#"{"app":"local.cua.never-resolved","action":{"type":{"_0":"owned-never-posted"}}}"#),
            ("ComputerUseIPCAppGetAppSnapshotRequest",0,#"{"app":"local.cua.never-resolved"}"#),
            ("ComputerUseIPCStartAudioRecordingRequest",0,"{"),
            ("ComputerUseIPCEventStreamStartRequest",0,"{"),
            ("ComputerUseIPCAppStartCaptureRequest",1,#"{"app":"local.cua.never-resolved","requestId":"capture-fallback"}"#),
            ("ComputerUseIPCAppNextCaptureUpdateRequest",1,"{"),
            ("ComputerUseIPCTimelineStartRequest",2,"{"),("ComputerUseIPCTimelineResumeRequest",2,"{")]
        for (name,source,raw) in routes {
            let result=await request(name,raw)
            check("actual XPC dispatch reaches correct permission source \(name)",result.code == CUErrorCode.permissionsPending.rawValue && fixture.inputs.last?["source"] as? Int == Int(source))
            let last=fixture.inputs.last!
            check("actual worker-to-actor dispatch retains metadata and capture ID \(name)",last["session"] as? String == "owned-native-ingress" && last["turn"] as? String == "" && (name == "ComputerUseIPCAppStartCaptureRequest" ? last["id"] as? String == "capture-fallback" : last["id"] is NSNull))
        }
        fixture.outcome = .denied
        let denied=await request("ComputerUseIPCAppGetAppSnapshotRequest",#"{"app":"local.cua.never-resolved"}"#)
        check("actual native dispatch preserves denied code and message",denied.code == CUErrorCode.permissionsNotGranted.rawValue && denied.message == "Computer Use permissions are not granted")
        for state in ServicePermissionGrantState.allCases {
            fixture.outcome = .appshotPermissionsAbandoned(state)
            let reply=await request("ComputerUseIPCAppStartCaptureRequest",#"{"app":"local.cua.never-resolved","requestId":"capture","permissionRequestId":"separate-owner"}"#)
            let value=try reply.data.map { try JSONSerialization.jsonObject(with:$0) as! [String:Any] }
            let expected=try ServicePermissionResult.appshotPermissionsAbandoned(state).appshotPermissionState()!.rawValue
            check("actual native reply encodes present abandonment state \(state)",value?["result"] as? String == "appshot_permissions_abandoned" && value?["permissionGrantState"] as? String == expected && fixture.inputs.last?["id"] as? String == "separate-owner")
        }
        let before=fixture.inputs.count,powerBefore=fixture.powerEvents.count
        fixture.outcome = .pending
        let early=await request("ComputerUseIPCAppStartRequest","{")
        check("malformed early app body fails before permission and activity",early.otherError && fixture.inputs.count == before && fixture.powerEvents.count == powerBefore)
        let late=await request("ComputerUseIPCStartAudioRecordingRequest","{")
        check("pending native permission precedes malformed late body",late.code == CUErrorCode.permissionsPending.rawValue && fixture.inputs.count == before+1)
        fixture.outcome = .granted
        let granted=await request("ComputerUseIPCStartAudioRecordingRequest","{")
        check("granted native permission allows late decode failure without starting audio",granted.otherError && fixture.inputs.count == before+2)
        check("native request scopes release every injected activity assertion",fixture.powerEvents.filter{$0.hasPrefix("acquire")}.count == fixture.powerEvents.filter{$0.hasPrefix("release")}.count)
        check("actor permission bridge restores caller telemetry after native requests",ComputerUseTelemetryContext.snapshot().isEmpty)
        check("native permission checks create no NSApplication",NSApp == nil)
        let passed=cases.allSatisfy{$0["passed"] as? Bool == true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,"all_owned_tasks_terminal":true,
            "actual_XPC_dispatch_decoder_metadata_worker_actor_and_error_reply_executed":true,
            "permission_results_and_power_assertions_injected":true,"actual_XPC_transport_or_signature_authentication":false,
            "input_capture_focus_AX_action_Chrome_installation_analytics_or_power":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native permission ingress: \(cases.filter{$0["passed"] as? Bool == true}.count)/\(cases.count)")
        return passed ? 0:3
    }
    static func installWireFixture(traceURL: URL) {
        // The real server and admission code still run. Only permission/power
        //providers are owned. Explicit development authorization is required.
        precondition(ProcessInfo.processInfo.environment[SenderAuthorization.developmentVariable] == "1")
        Dispatch.checkApplicationPolicy = { _ in }; Dispatch.checkGlobalConfiguration = {}
        Dispatch.requestActivity = .init(provider:.init(create:{_,id in id=0;return 0},release:{_ in 0}))
        Dispatch.ensureSystemPermissions = { source,id in
            try ServicePermissionRequestBridge(environment:.init(isMainThread:{Thread.isMainThread},wait:{try RequestRuntime.wait(for:$0,maximumSeconds:120)},ensure:{ source,id in
                let metadata=ComputerUseTelemetryContext.snapshot(),turn=ComputerUseTelemetryContext.snapshot().agentTurnID ?? "pending"
                let slow=turn == "slow"
                if slow { try? await Task.sleep(for:.seconds(2)) }
                let record:[String:Any]=["source":Int(source.rawValue),"id":id as Any? ?? NSNull(),"session":metadata.agentSessionID as Any? ?? NSNull(),"turn":turn,"cancelled":Task.isCancelled]
                var bytes=try! JSONSerialization.data(withJSONObject:record,options:.sortedKeys);bytes.append(10)
                if !FileManager.default.fileExists(atPath:traceURL.path) { _ = FileManager.default.createFile(atPath:traceURL.path,contents:Data()) }
                let file=try! FileHandle(forWritingTo:traceURL);try! file.seekToEnd();try! file.write(contentsOf:bytes);try! file.close()
                if turn == "denied" { return .denied }
                if let raw=UInt8(turn),let state=ServicePermissionGrantState(rawValue:raw) { return .appshotPermissionsAbandoned(state) }
                return .pending
            })).check(source:source,appshotRequestID:id)
        }
    }
}
