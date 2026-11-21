import AppKit
import Foundation

@MainActor enum NativeErrorClassificationChecks {
    static var typedFailures:[String:any Error] {[
        "sdk:senderProcessNotAuthenticated":ControllerNativeServerError.senderProcessNotAuthenticated,
        "sdk:couldNotGetRequestData":ControllerNativeServerError.couldNotGetRequestData,
        "sdk:couldNotGetRequestTypeName":ControllerNativeServerError.couldNotGetRequestTypeName,
        "sdk:permissionsNotGranted":ControllerNativeServerError.permissionsNotGranted,
        "sdk:incompatibleClientVersion":ControllerNativeServerError.incompatibleClientVersion,
        "sdk:permissionsPending":ControllerNativeServerError.permissionsPending,
        "sdk:couldNotGetSenderPID":ControllerNativeServerError.couldNotGetSenderPID,
        "sdk:couldNotGetBootstrapPort":ControllerNativeServerError.couldNotGetBootstrapPort,
        "sdk:screenLocked":ControllerNativeServerError.screenLocked,
        "sdk:agentTurnAlreadyEnded":ControllerNativeServerError.agentTurnAlreadyEnded,
        "sdk:messagesPermissionsPending":ControllerNativeServerError.messagesPermissionsPending,
        "sdk:messagesPermissionsDenied":ControllerNativeServerError.messagesPermissionsDenied,
        "sdk:messagesQueryTimedOut":ControllerNativeServerError.messagesQueryTimedOut,
        "sdk:messagesSendOutcomeUncertain":ControllerNativeServerError.messagesSendOutcomeUncertain,
        "sdk:calendarPermissionsPending":ControllerNativeServerError.calendarPermissionsPending,
        "sdk:calendarPermissionsDenied":ControllerNativeServerError.calendarPermissionsDenied,
        "sdk:couldNotResolveRequestType":ControllerNativeServerError.couldNotResolveRequestType("owned π 👋"),
        "sdk:unknown":ControllerNativeServerError.unknown("owned π 👋"),
        "sdk:messagesInvalidRequest":ControllerNativeServerError.messagesInvalidRequest("owned π 👋"),
        "sdk:messagesAmbiguousDestination":ControllerNativeServerError.messagesAmbiguousDestination("owned π 👋"),
        "sdk:calendarInvalidRequest":ControllerNativeServerError.calendarInvalidRequest("owned π 👋"),
        "sdk:unhandledEvent":ControllerNativeServerError.unhandledEvent(UInt32.max,2147483648),
        "sdk:plan:missing":ControllerNativeServerError.messagesSendPlanUnavailable(.missing),
        "sdk:plan:expired":ControllerNativeServerError.messagesSendPlanUnavailable(.expired),
        "sdk:plan:alreadyConsumed":ControllerNativeServerError.messagesSendPlanUnavailable(.alreadyConsumed),
        "sdk:rate:0":ControllerNativeServerError.messagesSendRateLimited(0),
        "sdk:rate:-9223372036854775808":ControllerNativeServerError.messagesSendRateLimited(Int64.min),
        "lock:unlockFailed":ControllerNativeLockAccessError.unlockFailed,
        "lock:physicalInputDetected":ControllerNativeLockAccessError.physicalInputDetected,
        "lock:requestHasNoThread":ControllerNativeLockAccessError.requestHasNoThread
    ]}
    static func fixtureFailure(_ value:ControllerNativeErrorFixture)->any Error {
        if value.name.hasPrefix("refetch:missingID:"),
           let id=Int(value.name.dropFirst("refetch:missingID:".count)) {
            return ControllerElementRefetchFailure.missingID(id)
        }
        if value.name.hasPrefix("refetch:unavailable:"),
           let raw=Int(value.name.dropFirst("refetch:unavailable:".count)),
           let reason=ControllerElementRefetchFailure.Reason(rawValue:raw) {
            return ControllerElementRefetchFailure.unavailable(reason)
        }
        if let error=typedFailures[value.name]{return error}
        return ControllerNativeMappedError(code:CUErrorCode(rawValue:Int(value.code))!,payload:value.payload)
    }
    private struct Reply:Sendable {
        let code:Int?
        let message:String?
        let userInfoKeys:[String]
        let domain:String?
    }
    static func run(output:URL,fixtures:URL)async throws->Int32 {
        let oldRuntime=Dispatch.nativeUsage,oldPolicy=Dispatch.checkApplicationPolicy,oldGlobal=Dispatch.checkGlobalConfiguration,
            oldPrepare=Dispatch.prepareAuthenticatedRequest,oldPermissions=Dispatch.ensureSystemPermissions,oldActivity=Dispatch.requestActivity,
            oldUsed=Dispatch.onApplicationUsed,oldResolve=Dispatch.resolveApplicationUseTarget,oldEnd=Dispatch.endAuthenticatedTurn
        defer{Dispatch.nativeUsage=oldRuntime;Dispatch.checkApplicationPolicy=oldPolicy;Dispatch.checkGlobalConfiguration=oldGlobal
            Dispatch.prepareAuthenticatedRequest=oldPrepare;Dispatch.ensureSystemPermissions=oldPermissions;Dispatch.requestActivity=oldActivity
            Dispatch.onApplicationUsed=oldUsed;Dispatch.resolveApplicationUseTarget=oldResolve;Dispatch.endAuthenticatedTurn=oldEnd}
        let trace=NativeDispatchTrace(),world=NativeDispatchWorld(trace:trace);world.install()
        let values=try JSONDecoder().decode(ControllerNativeErrorFixtures.self,from:Data(contentsOf:fixtures)).cases
        let thread="owned-C138-"+UUID().uuidString
        func request(_ type:DirectRequestType,body:Data,socket:Bool)async->Reply {
            return await withCheckedContinuation{continuation in DispatchQueue.global().async {
                var sender=SenderRequestContext(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[])
                sender.clientMetadata = .init(clientType:.nodeRepl,mcpRuntime:.nodeRepl)
                let metadata=ComputerUseJSONRPCCodexTurnMetadata(sessionID:thread,turnID:"native")
                do {
                    if socket {
                        let object=try JSONSerialization.jsonObject(with:body)
                        let message:JSON=["id":1,"jsonrpc":"2.0","method":"request","params":["clientApiVersion":kApiVersion,"requestType":type.rawValue,"request":object,"agentTurnMetadata":try JSONSerialization.jsonObject(with:JSONEncoder().encode(metadata))]]
                        let response=Dispatch.handle(message,cancelled:{false},peerPID:getpid(),senderContext:sender)
                        let error=response["error"] as? [String:Any]
                        continuation.resume(returning:.init(code:error?["code"] as? Int,message:error?["message"] as? String,userInfoKeys:[],domain:nil))
                    }else{
                        _ = try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:type.rawValue,request:body,metadata:JSONEncoder().encode(metadata),files:[],senderContext:sender,cancelled:{false})
                        continuation.resume(returning:.init(code:nil,message:nil,userInfoKeys:[],domain:nil))
                    }
                }catch{
                    let error=ComputerUseXPC.requestError(error)
                    continuation.resume(returning:.init(code:error.code,message:error.localizedDescription,userInfoKeys:error.userInfo.keys.sorted(),domain:error.domain))
                }
            }}
        }
        var observations:[[String:Any]]=[]
        var rows:[[String:Any]]=[]
        func check(_ name:String,_ passed:Bool){rows.append(["name":name,"passed":passed]);if !passed{print("FAIL: "+name)}}
        let start=await request(.appGetAppSnapshot,body:Data(#"{"app":"owned-native"}"#.utf8),socket:false)
        check("owned native instance is ready before controlled action failures",start.code==nil)
        for v in values where CUErrorCode(rawValue:Int(v.code)) != nil {
            let encoded=String(data:try JSONEncoder().encode(v),encoding:.utf8)!
            let body=try JSONSerialization.data(withJSONObject:["app":"owned-native","action":["type":["_0":"owned-C138-error:"+encoded]]])
            for socket in [false,true] {
                let reply=await request(.appPerformAction,body:body,socket:socket)
                observations.append(["name":v.name,"socket":socket,"actualCode":reply.code as Any? ?? NSNull(),"actualMessage":reply.message as Any? ?? NSNull(),"domain":reply.domain as Any? ?? NSNull(),"keys":reply.userInfoKeys,"expectedCode":v.code,"expectedMessage":socket ? v.description:v.payload])
                let envelope=socket || (reply.domain=="ComputerUseIPCXPC" && reply.userInfoKeys==[NSLocalizedDescriptionKey])
                check(v.name+(socket ? ":socket":":XPC"),reply.code==Int(v.code) && reply.message==(socket ? v.description:v.payload) && envelope)
            }
        }
        for raw in 0...4 {
            let failure=ControllerElementRefetchFailure.unavailable(.init(rawValue:raw)!)
            let mapped=ControllerNativeMappedError.classify(failure)
            let name="unavailable refetch reason matches the expected native classification \(raw)"

            guard let expected=values.first(where:{$0.name=="refetch:unavailable:\(raw)"}) else {
                check(name+" (fixture case missing)",false)
                continue
            }

            check(name,mapped.code.rawValue==Int(expected.code) && mapped.payload==expected.payload)
        }
        let foreign=NSError(domain:"ComputerUseIPCXPC",code:-10009,userInfo:[NSLocalizedDescriptionKey:"untrusted"])
        let mapped=ControllerNativeMappedError.classify(foreign)
        check("NSError domain and number alone do not impersonate a typed server error",mapped.code == .unknownError && mapped.payload==String(describing:foreign))
        await world.fixture.finish()
        check("error routing restores caller scope",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil && ComputerUseTelemetryContext.snapshot().isEmpty)
        let passed=rows.allSatisfy{$0["passed"] as? Bool==true}
        let report:[String:Any]=["passed":passed,"checks":rows,"observations":observations,"trace":trace.rows,"ordinary_socket_and_XPC_dispatch_executed":true,
            "typed_SDK_and_lock_error_families_executed":true,"actual_XPC_connection_admission":false,
            "native_effects_and_permission_preparation_intercepted":true,
            "actual_input_capture_focus_or_general_clipboard":false,"full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native error dispatch: \(rows.filter{$0["passed"] as? Bool==true}.count)/\(rows.count)")
        return passed ? 0:3
    }
}
