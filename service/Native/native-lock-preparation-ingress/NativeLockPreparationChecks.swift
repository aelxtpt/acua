import AppKit
import Foundation

private final class LockPreparationTrace:@unchecked Sendable {
    private let lock=NSLock();private var stored:[String]=[]
    func add(_ value:String){lock.withLock{stored.append(value)}}
    func clear(){lock.withLock{stored=[]}}
    var values:[String]{lock.withLock{stored}}
}
@MainActor private final class LockPreparationController:LockScreenController {
    let trace:LockPreparationTrace
    var locked=true,unlocks=0,changesState=false,throwsOnUnlock=false
    init(_ trace:LockPreparationTrace){self.trace=trace}
    var isLocked:Bool{trace.add("sample:\(locked)");return locked}
    func unlock()async throws->Bool {
        unlocks+=1;trace.add("unlock")
        if throwsOnUnlock{throw CocoaError(.fileReadUnknown)}
        if changesState{locked=false}
        return false
    }
    func lock(){trace.add("lock");locked=true}
}
@MainActor private final class LockPreparationMonitor:LockScreenMonitor {
    let trace:LockPreparationTrace
    init(_ trace:LockPreparationTrace){self.trace=trace}
    func start(onChange:@escaping @MainActor (Bool)->Void){trace.add("monitor.start")}
    func stop(){trace.add("monitor.stop")}
}
@MainActor private final class LockPreparationGuardian:LockScreenGuardian {
    let trace:LockPreparationTrace
    init(_ trace:LockPreparationTrace){self.trace=trace}
    func setPhysicalInputHandler(_ handler:@escaping @MainActor ()->Void){}
    func setPendingUnlockPhysicalInputHandler(_ handler:@escaping @MainActor ()->Void){}
    func withUnlockGuard(threadID:String,perform:@escaping @MainActor ()async throws->Bool)async throws->Bool {
        trace.add("guard:"+threadID);return try await perform()
    }
    func retainAutoUnlockedLease(threadID:String){trace.add("retain:"+threadID)}
    func releaseAutoUnlockedLease(threadID:String){trace.add("release:"+threadID)}
}
@MainActor enum NativeLockPreparationChecks {
    // Auto-unlock is allowed only for a responsible process signed by the
    // service's own team with an ACUA host bundle identifier. The dispatcher
    // reads the team from this process's own code signature, so the fixture
    // uses that team (TESTTEAM01 only stands in for an unsigned build).
    static let ownTeam = AcuaOwnIdentity.signingTeam() ?? "TESTTEAM01", foreignTeam = "OTHERTEAM1"
    static let ownHostBundle = "com.aex.computeruse.client", foreignHostBundle = "com.example.agent"
    private enum Scenario:String,CaseIterable,Sendable {
        case missingThread,emptyThread,failed,controllerThrow,suppressed,alreadyUnlocked,featureDisabled,untrusted,wrongTeam,wrongBundle,postUnlockSample,endedTurn,exempt
        var allows:Bool{![Self.untrusted,.wrongTeam,.wrongBundle,.exempt].contains(self)}
        var prepares:Bool{self != .exempt}
        var reachesPermissions:Bool{[Self.alreadyUnlocked,.featureDisabled,.untrusted,.wrongTeam,.wrongBundle,.postUnlockSample,.exempt].contains(self)}
        var expectedUnlocks:Int{self == .postUnlockSample || self == .controllerThrow ? 1:([Self.failed,.emptyThread].contains(self) ? 2:0)}
    }
    private struct Reply:Sendable {let code:Int?;let message:String?;let domain:String?;let keys:[String]}
    static func run(output:URL,fixtures:URL)async throws->Int32 {
        struct Corpus:Decodable{let cases:[ControllerNativeErrorFixture]}
        let corpus=try JSONDecoder().decode(Corpus.self,from:Data(contentsOf:fixtures)).cases
        func expectedPayload(_ name:String)throws->String {
            guard let value=corpus.first(where:{$0.name=="lock:"+name}) else{throw CocoaError(.fileReadCorruptFile)}
            return value.payload
        }
        let missing=try expectedPayload("requestHasNoThread"),suppressed=try expectedPayload("physicalInputDetected"),failed=try expectedPayload("unlockFailed")
        let boundary="owned C140 permission boundary"
        let oldRuntime=Dispatch.nativeUsage,oldPolicy=Dispatch.checkApplicationPolicy,oldGlobal=Dispatch.checkGlobalConfiguration,
            oldPrepare=Dispatch.prepareAuthenticatedRequest,oldPermissions=Dispatch.ensureSystemPermissions,oldActivity=Dispatch.requestActivity,
            oldUsed=Dispatch.onApplicationUsed,oldResolve=Dispatch.resolveApplicationUseTarget,oldEnd=Dispatch.endAuthenticatedTurn
        defer{Dispatch.nativeUsage=oldRuntime;Dispatch.checkApplicationPolicy=oldPolicy;Dispatch.checkGlobalConfiguration=oldGlobal
            Dispatch.prepareAuthenticatedRequest=oldPrepare;Dispatch.ensureSystemPermissions=oldPermissions;Dispatch.requestActivity=oldActivity
            Dispatch.onApplicationUsed=oldUsed;Dispatch.resolveApplicationUseTarget=oldResolve;Dispatch.endAuthenticatedTurn=oldEnd}
        let world=NativeDispatchWorld(trace:.init());world.install()
        var checks:[[String:Any]]=[],observations:[[String:Any]]=[]
        func check(_ name:String,_ value:Bool){checks.append(["name":name,"passed":value]);if !value{print("FAIL: "+name)}}
        for (error,payload) in [(LockScreenAutoUnlockCoordinator.AccessError.missingThreadID,missing),(.suppressedUntilManualUnlock,suppressed),(.unlockFailed,failed)] {
            let mapped=ControllerNativeMappedError.classify(error),xpc=ComputerUseXPC.requestError(error)
            check("actual coordinator error maps before both transport descriptions: "+payload,mapped.code == .screenLocked && mapped.payload==payload && mapped.socketDescription==payload && xpc.code == -10020 && xpc.localizedDescription==payload && xpc.domain=="ComputerUseIPCXPC" && xpc.userInfo.keys.sorted()==[NSLocalizedDescriptionKey])
        }
        let parser:[(String,[String:Any]?,Bool)]=[
            ("absent",nil,false),("empty",[:],false),("locked",["CGSSessionScreenIsLocked":true],true),
            ("unlocked",["CGSSessionScreenIsLocked":false],false),("null",["CGSSessionScreenIsLocked":NSNull()],false),
            ("string",["CGSSessionScreenIsLocked":"true"],false),("array",["CGSSessionScreenIsLocked":[true]],false),
            ("wrong key",["locked":true],false),("bridged true",["CGSSessionScreenIsLocked":NSNumber(value:true)],true),
            ("bridged false",["CGSSessionScreenIsLocked":NSNumber(value:false)],false),
            ("numeric one",["CGSSessionScreenIsLocked":NSNumber(value:1)],true),("numeric zero",["CGSSessionScreenIsLocked":NSNumber(value:0)],false)]
        for (name,value,expected) in parser{check("CGSession optional Bool parser: "+name,SystemLockScreenSession.isLocked(value)==expected)}
        for scenario in Scenario.allCases {
            for socket in [false,true] {
                let trace=LockPreparationTrace(),controller=LockPreparationController(trace)
                controller.locked=scenario != .alreadyUnlocked;controller.changesState=scenario == .postUnlockSample || scenario == .suppressed
                controller.throwsOnUnlock=scenario == .controllerThrow
                let coordinator=LockScreenAutoUnlockCoordinator(isAutoUnlockEnabled:{scenario != .featureDisabled},controller:controller,monitor:LockPreparationMonitor(trace),guardian:LockPreparationGuardian(trace))
                if scenario == .suppressed {
                    try await coordinator.prepareForRequest(threadID:"owned-seed")
                    guard coordinator.hasActiveAutoUnlock else{throw CocoaError(.fileReadCorruptFile)}
                    coordinator.handlePhysicalUserInteraction();controller.locked=true;controller.unlocks=0
                }
                trace.clear()
                let owner=ServiceAuthenticatedPreparationOwner(environment:.init(resetInactivity:{trace.add("idle")},turnAlreadyEnded:{_ in trace.add("turn");return scenario == .endedTurn},preparePIP:{trace.add("pip:"+$0+":"+$1)},endPIP:{trace.add("end-pip:"+$0)},makeCoordinator:{trace.add("coordinator");return coordinator}))
                Dispatch.prepareAuthenticatedRequest={prepares,unlock in
                    trace.add("flags:\(prepares):\(unlock)")
                    try ServiceAuthenticatedRequestBridge(environment:.init(isMainThread:{Thread.isMainThread},wait:{try RequestRuntime.wait(for:$0,maximumSeconds:120)},prepare:{a,b in
                        trace.add("actor:"+(ComputerUseTelemetryContext.snapshot().agentSessionID ?? "nil"))
                        try await owner.prepare(preparesTurn:a,allowsAutoUnlock:b)
                    })).prepare(preparesTurn:prepares,allowsAutoUnlock:unlock)
                }
                Dispatch.ensureSystemPermissions={_,_ in trace.add("permissions");throw ControllerNativeServerError.messagesInvalidRequest(boundary)}
                let session:String?=scenario == .missingThread ? nil:(scenario == .emptyThread ? "":"owned-C140-"+scenario.rawValue)
                let metadata=ComputerUseJSONRPCCodexTurnMetadata(sessionID:session,turnID:"native")
                let identity:SenderProcessIdentity?=scenario == .untrusted ? nil:.init(team:scenario == .wrongTeam ? foreignTeam:ownTeam,bundleID:scenario == .wrongBundle ? foreignHostBundle:ownHostBundle)
                let sender=SenderRequestContext(senderPID:getpid(),responsibleIdentity:identity,ancestorIdentities:[])
                let route=scenario == .exempt ? "ComputerUseIPCTimelineStartRequest":"ComputerUseIPCAppGetAppSnapshotRequest"
                let reply:Reply=await withCheckedContinuation{continuation in DispatchQueue.global().async {
                    let body:JSON=["app":"owned-native"]
                    do {
                        if socket {
                            let params:JSON=["clientApiVersion":kApiVersion,"requestType":route,"request":body,"agentTurnMetadata":try JSONSerialization.jsonObject(with:JSONEncoder().encode(metadata))]
                            let result=Dispatch.handle(["id":1,"jsonrpc":"2.0","method":"request","params":params],cancelled:{false},peerPID:getpid(),senderContext:sender)
                            let error=result["error"] as? JSON
                            continuation.resume(returning:.init(code:error?["code"] as? Int,message:error?["message"] as? String,domain:nil,keys:[]))
                        }else {
                            _ = try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:route,request:JSONSerialization.data(withJSONObject:body),metadata:JSONEncoder().encode(metadata),files:[],senderContext:sender,cancelled:{false})
                            continuation.resume(returning:.init(code:nil,message:nil,domain:nil,keys:[]))
                        }
                    }catch {
                        let error=ComputerUseXPC.requestError(error)
                        continuation.resume(returning:.init(code:error.code,message:error.localizedDescription,domain:error.domain,keys:error.userInfo.keys.sorted()))
                    }
                }}
                let code=scenario.reachesPermissions ? -10025:(scenario == .endedTurn ? -10021:-10020)
                let payload=scenario.reachesPermissions ? boundary:(scenario == .endedTurn ? ControllerNativeClientErrorCodec.constants[-10021]!:(scenario == .missingThread ? missing:(scenario == .suppressed ? suppressed:failed)))
                let expected=socket ? ControllerNativeClientErrorCodec.describe(code:Int32(code),payload:payload):payload
                let values=trace.values
                let expectedOwner=scenario.allows && scenario != .endedTurn
                let passed=reply.code==code && reply.message==expected && (socket || (reply.domain=="ComputerUseIPCXPC" && reply.keys==[NSLocalizedDescriptionKey])) && values.first=="flags:\(scenario.prepares):\(scenario.allows)" && values.contains("idle") && values.contains("actor:"+(session ?? "nil")) && values.contains("permissions")==scenario.reachesPermissions && controller.unlocks==scenario.expectedUnlocks && owner.hasCoordinator==expectedOwner && !values.contains("lock")
                check("actual worker actor owner coordinator gate "+scenario.rawValue+(socket ? ":socket":":XPC"),passed)
                observations.append(["name":scenario.rawValue,"socket":socket,"code":reply.code as Any? ?? NSNull(),"message":reply.message as Any? ?? NSNull(),"expectedCode":code,"expectedMessage":expected,"unlocks":controller.unlocks,"expectedUnlocks":scenario.expectedUnlocks,"hasCoordinator":owner.hasCoordinator,"expectedHasCoordinator":expectedOwner,"trace":values])
                if !passed{print(String(describing:reply));print(values)}
            }
        }
        await world.fixture.finish()
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        let value:[String:Any]=["passed":passed,"checks":checks,"observations":observations,"actual_dispatch_selection_worker_actor_bridge_preparation_owner_and_coordinator_executed":true,"preparation_logic_intercepted":false,"permission_boundary_and_lock_PIP_monitor_guardian_dependencies_owned":true,"actual_system_unlock_lock_helper_PIP_or_input":false,"actual_authenticated_XPC_connection_admission":false,"full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native lock preparation ingress: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
