import AppKit
import Foundation

private final class PolicyTrace: @unchecked Sendable {
    private let lock=NSLock();private var stored=[String]()
    func add(_ value:String){lock.withLock{stored.append(value)}}
    var values:[String]{lock.withLock{stored}}
    func clear(){lock.withLock{stored.removeAll()}}
}
private struct DefaultPolicyCheck: Sendable {let name:String;let passed:Bool}
private struct PolicyReply: Sendable {let code:Int?;let message:String?;let data:Data?;let decodingError:Bool}
@MainActor enum NativePolicyOrderingBindingChecks {
    static func run(output:URL) async throws -> Int32 {
        let oldApp=Dispatch.checkApplicationPolicy,oldConfig=Dispatch.checkGlobalConfiguration,oldEnsure=Dispatch.ensureSystemPermissions,oldActivity=Dispatch.requestActivity
        let oldIdle=Dispatch.idleTimer
        defer{Dispatch.checkApplicationPolicy=oldApp;Dispatch.checkGlobalConfiguration=oldConfig;Dispatch.ensureSystemPermissions=oldEnsure;Dispatch.requestActivity=oldActivity;Dispatch.idleTimer=oldIdle}
        var cases=[[String:Any]]()
        func check(_ name:String,_ value:Bool){cases.append(["name":name,"passed":value]);if !value{print("FAIL: "+name)}}
        let trace=PolicyTrace()
        Dispatch.requestActivity = .init(provider:.init(create:{kind,id in id=kind == .remoteUserActivity ? 41:42;trace.add("acquire:\(id)");return 0},release:{trace.add("release:\($0)");return 0}))
        Dispatch.checkApplicationPolicy={app in trace.add("app-policy:\(app)");throw ServiceError(.appNotAllowed,"owned-policy-error")}
        Dispatch.checkGlobalConfiguration={trace.add("configuration");throw ServiceError(.unknownError,"Computer Use is disabled by your configuration.")}
        Dispatch.ensureSystemPermissions={_,_ in trace.add("permissions");return .pending}
        func request(_ type:String,_ body:String,metadata:Data?=nil)async->PolicyReply{
            await withCheckedContinuation{continuation in DispatchQueue.global(qos:.userInitiated).async{
                do{let data=try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:type,request:Data(body.utf8),metadata:metadata,files:[],senderContext:.init(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[]),cancelled:{false});continuation.resume(returning:.init(code:nil,message:nil,data:data,decodingError:false))}
                catch let error as ServiceError{continuation.resume(returning:.init(code:error.code.rawValue,message:error.message,data:nil,decodingError:false))}
                catch{continuation.resume(returning:.init(code:nil,message:nil,data:nil,decodingError:true))}
            }}
        }
        for (name,body) in [("ComputerUseIPCAppStartRequest",#"{"app":"owned-target"}"#),("ComputerUseIPCAppGetAppSnapshotRequest",#"{"app":"owned-target"}"#),("ComputerUseIPCAppPerformActionRequest",#"{"app":"owned-target","action":{"type":{"_0":"never-posted"}}}"#),("ComputerUseIPCAppModifyRequest",#"{"app":"owned-target","modification":{"activate":{}}}"#)] {
            trace.clear();let reply=await request(name,body)
            check("actual native app policy precedes permissions and activity \(name)",reply.code == CUErrorCode.appNotAllowed.rawValue && reply.message == "owned-policy-error" && trace.values == ["app-policy:owned-target"])
        }
        trace.clear();let deactivate=await request("ComputerUseIPCAppModifyRequest",#"{"app":"owned-target","modification":{"deactivate":{}}}"#)
        check("native deactivate skips app policy while retaining permission hook",deactivate.code == CUErrorCode.permissionsPending.rawValue && trace.values == ["acquire:41","acquire:42","permissions","release:42","release:41"])
        for type in ["ComputerUseIPCListAppsRequest","ComputerUseIPCStartAudioRecordingRequest"] {
            trace.clear();let reply=await request(type,"{")
            check("actual XPC configuration failure precedes malformed late body \(type)",reply.code == CUErrorCode.unknownError.rawValue && reply.message == "Computer Use is disabled by your configuration." && trace.values == ["configuration"])
        }
        trace.clear();let modifyBad=await request("ComputerUseIPCAppModifyRequest","{")
        check("actual native AppModify now decodes before policy activity and permission",modifyBad.decodingError && trace.values.isEmpty)
        trace.clear();let policyBad=await request("ComputerUseIPCAppPolicyRequest","{")
        check("dedicated policy path rejects malformed input without generic prefix",policyBad.decodingError && trace.values.isEmpty)
        trace.clear();let missingPolicy=await request("ComputerUseIPCAppPolicyRequest",#"{"app":"/private/tmp/cua-C113-never-installed.app"}"#)
        check("dedicated native policy path resolves target before any generic operation",missingPolicy.code == CUErrorCode.invalidApp.rawValue && trace.values.isEmpty)
        Dispatch.checkApplicationPolicy={app in trace.add("app-policy:\(app)")}
        Dispatch.checkGlobalConfiguration={trace.add("configuration")}
        trace.clear();let allowed=await request("ComputerUseIPCAppStartRequest",#"{"app":"owned-target"}"#)
        check("allowed native app policy proceeds to activity then permissions",allowed.code == CUErrorCode.permissionsPending.rawValue && trace.values == ["app-policy:owned-target","acquire:41","acquire:42","permissions","release:42","release:41"])
        trace.clear();let allowedAudio=await request("ComputerUseIPCStartAudioRecordingRequest","{")
        check("enabled native configuration proceeds to activity and permission before late decode",allowedAudio.code == CUErrorCode.permissionsPending.rawValue && trace.values == ["configuration","acquire:41","acquire:42","permissions","release:42","release:41"])
        // End a wholly owned turn, then verify that its failed preparation still
        //resets inactivity. No real session, PIP, recording or input is started.
        trace.clear();let ended=await request("ComputerUseIPCTurnEndedRequest",#"{"threadID":"owned-C113-unused","turnID":"owned-C113-ended"}"#)
        check("turn-ended request bypasses policy activity permission and idle reset",ended.data != nil && trace.values.isEmpty)
        let idleTrace=PolicyTrace()
        let timer=ServiceIdleTimer(idlePeriod:.milliseconds(20),keepAlive:{false},onIdle:{idleTrace.add("idle")})
        Dispatch.idleTimer=timer
        let endedMetadata=Data(#"{"turn_id":"owned-C113-ended"}"#.utf8)
        let stopped=await request("ComputerUseIPCAppGetAppSnapshotRequest",#"{"app":"owned-target"}"#,metadata:endedMetadata)
        for _ in 0..<100 where idleTrace.values.isEmpty{try await Task.sleep(for:.milliseconds(5))}
        check("native inactivity reset precedes ended-turn failure",stopped.code == CUErrorCode.agentTurnAlreadyEnded.rawValue && idleTrace.values == ["idle"] && !trace.values.contains("permissions"))
        timer.stop();Dispatch.idleTimer=oldIdle
        check("native policy ordering never initializes NSApplication",NSApp == nil)
        return try write(cases,output:output,defaults:false)
    }
    static func runDefaults(output:URL)async throws->Int32{
        // The caller points ACUA_HOME at an owned directory whose config.toml disables Computer Use.
        let configuration = AcuaConfigurationLocation.fileURL()
        let disabledConfiguration = (try? String(contentsOf: configuration, encoding: .utf8)) ?? ""
        precondition(ProcessInfo.processInfo.environment[AcuaConfigurationLocation.homeEnvironmentVariable] != nil
            && disabledConfiguration.contains("enabled = false"), "Set ACUA_HOME to a directory with [apps] enabled = false")
        var cases=[[String:Any]]()
        func check(_ name:String,_ value:Bool){cases.append(["name":name,"passed":value]);if !value{print("FAIL: "+name)}}
        let value:[DefaultPolicyCheck]=await withCheckedContinuation{continuation in DispatchQueue.global(qos:.userInitiated).async{
            var checks=[DefaultPolicyCheck]()
            func record(_ name:String,_ okay:Bool){checks.append(.init(name:name,passed:okay))}
            let finder="/System/Library/CoreServices/Finder.app"
            do{try ComputerUsePolicyIPC.requireApplicationAllowed(finder);record("default native application policy rejects disabled config",false)}
            catch let e as ServiceError{record("default native application policy rejects disabled config",e.code == .appNotAllowed && e.message == "Computer Use is not allowed to use the app 'com.apple.finder' for safety reasons.")}
            catch{record("default native application policy rejects disabled config",false)}
            do{try ComputerUsePolicyIPC.requireEnabled();record("default native global policy reads disabled config",false)}
            catch let e as ServiceError{record("default native global policy reads disabled config",e.code == .unknownError && e.message == "Computer Use is disabled by your configuration.")}
            catch{record("default native global policy reads disabled config",false)}
            do{let result=try ComputerUsePolicyIPC.perform(finder);record("default native policy query returns denied descriptor",result["decision"] as? String == "denied" && (result["target"] as? [String:Any])?["bundleIdentifier"] as? String == "com.apple.finder")}
            catch{record("default native policy query returns denied descriptor",false)}
            do{try ComputerUsePolicyIPC.requireApplicationAllowed("/private/tmp/cua-C113-never-installed.app");record("default target lookup error precedes disabled policy",false)}
            catch let e as ServiceError{record("default target lookup error precedes disabled policy",e.code == .invalidApp)}
            catch{record("default target lookup error precedes disabled policy",false)}
            continuation.resume(returning:checks)
        }}
        cases+=value.map{["name":$0.name,"passed":$0.passed]}
        check("default native policy reader creates no NSApplication",NSApp == nil)
        return try write(cases,output:output,defaults:true)
    }
    static func installWireFixture(traceURL:URL){
        NativePermissionIngressBindingChecks.installWireFixture(traceURL:traceURL)
        Dispatch.checkApplicationPolicy={app in
            if ComputerUseTelemetryContext.snapshot().agentTurnID == "app-deny"{
                throw ServiceError(.appNotAllowed,"Computer Use is not allowed to use the app '\(app)' for safety reasons.")
            }
        }
        Dispatch.checkGlobalConfiguration={
            if ComputerUseTelemetryContext.snapshot().agentTurnID == "config-deny"{throw ServiceError(.unknownError,"Computer Use is disabled by your configuration.")}
        }
    }
    private static func write(_ cases:[[String:Any]],output:URL,defaults:Bool)throws->Int32{
        let passed=cases.allSatisfy{$0["passed"] as? Bool == true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,"all_owned_tasks_terminal":true,"default_policy_reader_and_cache_executed":defaults,"user_config_modified":false,"owned_acua_home_used":defaults,"physical_input_capture_focus_AX_action_or_installation":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native policy ordering: \(cases.filter{$0["passed"] as? Bool == true}.count)/\(cases.count)")
        return passed ? 0:3
    }
}
