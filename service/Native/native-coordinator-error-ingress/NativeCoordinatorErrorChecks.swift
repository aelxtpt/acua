import AppKit
import Foundation

@MainActor enum NativeCoordinatorErrorChecks {
    private struct Reply:Sendable {let code:Int?;let message:String?;let domain:String?;let keys:[String]}
    private static var wireWorld:NativeDispatchWorld?
    static func installWire(trace:URL)throws {
        let world=NativeDispatchWorld(trace:.init(file:trace));world.install();wireWorld=world
        let values=try NativeCoordinatorProducerCases.cases()
        Dispatch.prepareAuthenticatedRequest={_,_ in
            let name=ComputerUseTelemetryContext.snapshot().agentSessionID ?? ""
            guard name.hasPrefix("owned-C139:"),let selected=values.first(where:{$0.name==String(name.dropFirst("owned-C139:".count))}) else{throw ControllerNativeServerError.messagesInvalidRequest("Unknown owned coordinator fixture")}
            world.trace.add("producer:"+selected.name)
            _ = try selected.operation()
            throw ControllerNativeServerError.messagesInvalidRequest("Owned producer unexpectedly returned")
        }
    }
    static func run(output:URL)async throws->Int32 {
        let oldRuntime=Dispatch.nativeUsage,oldPolicy=Dispatch.checkApplicationPolicy,oldGlobal=Dispatch.checkGlobalConfiguration,
            oldPrepare=Dispatch.prepareAuthenticatedRequest,oldPermissions=Dispatch.ensureSystemPermissions,oldActivity=Dispatch.requestActivity,
            oldUsed=Dispatch.onApplicationUsed,oldResolve=Dispatch.resolveApplicationUseTarget,oldEnd=Dispatch.endAuthenticatedTurn
        defer{Dispatch.nativeUsage=oldRuntime;Dispatch.checkApplicationPolicy=oldPolicy;Dispatch.checkGlobalConfiguration=oldGlobal
            Dispatch.prepareAuthenticatedRequest=oldPrepare;Dispatch.ensureSystemPermissions=oldPermissions;Dispatch.requestActivity=oldActivity
            Dispatch.onApplicationUsed=oldUsed;Dispatch.resolveApplicationUseTarget=oldResolve;Dispatch.endAuthenticatedTurn=oldEnd}
        let world=NativeDispatchWorld(trace:.init());world.install()
        var checks:[[String:Any]]=[],observations:[[String:Any]]=[]
        let cases=try NativeCoordinatorProducerCases.cases()
        for selected in cases {
            Dispatch.prepareAuthenticatedRequest={_,_ in _ = try selected.operation()}
            for socket in [false,true] {
                let reply:Reply=await withCheckedContinuation{continuation in DispatchQueue.global().async {
                    let sender=SenderRequestContext(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[])
                    let metadata=ComputerUseJSONRPCCodexTurnMetadata(sessionID:"owned-C139:"+selected.name,turnID:"native")
                    do {
                        if socket {
                            let body=try JSONSerialization.jsonObject(with:selected.body)
                            let params:JSON=["clientApiVersion":kApiVersion,"requestType":selected.route,"request":body,"agentTurnMetadata":try JSONSerialization.jsonObject(with:JSONEncoder().encode(metadata))]
                            let result=Dispatch.handle(["id":1,"jsonrpc":"2.0","method":"request","params":params],cancelled:{false},peerPID:getpid(),senderContext:sender)
                            let error=result["error"] as? JSON
                            continuation.resume(returning:.init(code:error?["code"] as? Int,message:error?["message"] as? String,domain:nil,keys:[]))
                        }else {
                            _ = try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:selected.route,request:selected.body,metadata:JSONEncoder().encode(metadata),files:[],senderContext:sender,cancelled:{false})
                            continuation.resume(returning:.init(code:nil,message:nil,domain:nil,keys:[]))
                        }
                    }catch {
                        let error=ComputerUseXPC.requestError(error)
                        continuation.resume(returning:.init(code:error.code,message:error.localizedDescription,domain:error.domain,keys:error.userInfo.keys.sorted()))
                    }
                }}
                let expected=socket ? selected.socketDescription:selected.payload
                let passed=reply.code==Int(selected.code) && reply.message==expected && (socket || (reply.domain=="ComputerUseIPCXPC" && reply.keys==[NSLocalizedDescriptionKey]))
                checks.append(["name":selected.name+(socket ? ":socket":":XPC"),"passed":passed])
                observations.append(["name":selected.name,"socket":socket,"code":reply.code as Any? ?? NSNull(),"message":reply.message as Any? ?? NSNull(),"expectedCode":selected.code,"expectedMessage":expected])
                if !passed{print("FAIL: "+selected.name+": "+String(describing:reply))}
            }
        }
        await world.fixture.finish()
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        let value:[String:Any]=["passed":passed,"checks":checks,"observations":observations,
            "real_coordinator_producer_queues_and_validations_executed":true,"producer_injection_boundary":"authenticated preparation hook",
            "full_normal_coordinator_route_dispatch_accepted":false,"permissions_databases_contacts_delivery_EventKit_injected":true,
            "actual_message_sent_or_calendar_modified":false,"actual_input_capture_focus_or_general_clipboard":false,
            "full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native coordinator error ingress: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
