import AppKit
import Foundation

final class NativeDispatchTrace: @unchecked Sendable {
    private let lock=NSLock()
    private var values:[[String:Any]]=[]
    private var failed=false
    let file:URL?
    init(file:URL?=nil){self.file=file}
    func add(_ phase:String) {
        let meta=ComputerUseTelemetryContext.snapshot()
        let row:[String:Any]=["phase":phase,"thread":meta.agentSessionID as Any? ?? NSNull(),"turn":meta.agentTurnID as Any? ?? NSNull(),
            "peer":RequestRuntime.peerPID as Any? ?? NSNull(),"sender":RequestRuntime.senderContext?.senderPID as Any? ?? NSNull()]
        lock.withLock {
            values.append(row)
            guard let file else{return}
            do {
                var bytes=try JSONSerialization.data(withJSONObject:row,options:.sortedKeys);bytes.append(10)
                if !FileManager.default.fileExists(atPath:file.path){_ = FileManager.default.createFile(atPath:file.path,contents:Data())}
                let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:bytes);try handle.close()
            }catch{failed=true}
        }
    }
    var rows:[[String:Any]]{lock.withLock{values}}
    var phases:[String]{rows.compactMap{$0["phase"] as? String}}
    var writeFailed:Bool{lock.withLock{failed}}
}
actor NativeDispatchGate {
    private var entered=false,release:CheckedContinuation<Void,Never>?
    func hold()async{entered=true;await withCheckedContinuation{release=$0}}
    func wait()async{while !entered{await Task.yield()}}
    func finish(){release?.resume();release=nil}
}
private final class NativeDispatchCancel: @unchecked Sendable {
    private let lock=NSLock();private var flag=false
    func set(){lock.withLock{flag=true}}
    var value:Bool{lock.withLock{flag}}
}
@MainActor final class NativeDispatchWorld {
    let fixture=LifecycleFixture()
    let trace:NativeDispatchTrace
    var gate:NativeDispatchGate?
    var factoryCalls=0
    init(trace:NativeDispatchTrace){self.trace=trace}
    var resolver:ControllerApplicationTargetResolver {
        .init(environment:.init(bundleIdentifierAtPath:{query in
            self.trace.add("resolve:"+query)
            return ["owned-native",self.fixture.target.identifier].contains(query) ? self.fixture.target.bundleIdentifier:nil
        },bundleIdentifierAtURL:{_ in nil},canonicalURL:{_ in self.fixture.target.url},installedURLs:{_ in []},runningURLs:{_ in []},pathForName:{_ in nil}))
    }
    var facade:ControllerNativeServiceFacade {
        factoryCalls+=1
        let state=ControllerNativeAppSnapshotRequestEnvironment(capture:{_,diff in
            self.trace.add("state:\(diff)");return try NativeSecondaryScrollDataAppSnapshotBindingChecks.result(self.fixture.data)
        },blockedURL:{_,_ in nil},scheduleFinished:{_ in self.trace.add("state.finished")},instructions:{_ in "owned native instructions"})
        let action=ControllerNativeActionRequestEnvironment(focus:{_ in self.trace.add("focus")},activity:{_,value in self.trace.add("activity:\(value)")},dispatch:{_,action,capture in
            let kind:String
            switch action {
            case .click:kind="click";case .drag:kind="drag";case .type:kind="type";case .pressKey:kind="pressKey";case .paste:kind="paste";case .scroll:kind="scroll";case .setValue:kind="setValue";case .selectText:kind="selectText";case .performSecondaryAction:kind="performSecondaryAction"
            }
            self.trace.add("action:"+kind+":\(capture)")
            if case .type(let text)=action,text.hasPrefix("owned-C138-error:"),
               let bytes=text.dropFirst("owned-C138-error:".count).data(using:.utf8),
               let error=try? JSONDecoder().decode(ControllerNativeErrorFixture.self,from:bytes),
               CUErrorCode(rawValue:Int(error.code)) != nil {throw NativeErrorClassificationChecks.fixtureFailure(error)}
            if case .type(let text)=action,text=="owned wait",let gate=self.gate{await gate.hold();self.trace.add("action.released")}
            if case .type(let text)=action,text=="owned blocked"{throw ControllerAppSnapshotRequestFailure.blockedURL(URL(string:"https://EXAMPLE.invalid/a?q=1#f")!)}
            return capture ? try NativeSecondaryScrollDataAppSnapshotBindingChecks.result(self.fixture.data):nil
        },blockedURL:{_,_ in nil})
        return .init(lifecycle:fixture.lifecycle,resolver:resolver,appSnapshotEnvironment:state,actionEnvironment:action)
    }
    func runtime()->ControllerNativeUsageRuntime {
        .init(bindings:fixture.bindings,resolver:{self.resolver},assembly:{preconditionFailure("No native assembly in owned fixture")},
            fixture:{self.facade},observe:{_,_ in self.trace.add("observe")})
    }
    func install() {
        let trace=trace
        Dispatch.nativeUsage=runtime()
        Dispatch.checkApplicationPolicy={_ in trace.add("policy")}
        Dispatch.checkGlobalConfiguration={trace.add("configuration")}
        Dispatch.prepareAuthenticatedRequest={_,_ in trace.add("prepare")}
        Dispatch.ensureSystemPermissions={_,_ in trace.add("permissions");return .granted}
        Dispatch.requestActivity = .init(provider:.init(create:{_,id in id=0;return 0},release:{_ in 0}))
        Dispatch.onApplicationUsed={id in trace.add("used:"+id);Dispatch.applicationUsed(id)}
        Dispatch.resolveApplicationUseTarget={try Dispatch.nativeUsage.resolveIdentifier($0)}
        Dispatch.endAuthenticatedTurn={_ in trace.add("turn.ended")}
    }
}
private struct NativeDispatchReply:Sendable {
    let data:Data?
    let code:Int?
    let message:String?
}
@MainActor enum NativeServiceDispatchChecks {
    private static var wireWorld:NativeDispatchWorld?
    static func installWire(trace:URL) {
        let world=NativeDispatchWorld(trace:.init(file:trace));world.install();wireWorld=world
    }
    static func run(output:URL) async throws -> Int32 {
        let oldRuntime=Dispatch.nativeUsage,oldPolicy=Dispatch.checkApplicationPolicy,oldGlobal=Dispatch.checkGlobalConfiguration,
            oldPrepare=Dispatch.prepareAuthenticatedRequest,oldPermissions=Dispatch.ensureSystemPermissions,oldActivity=Dispatch.requestActivity,
            oldUsed=Dispatch.onApplicationUsed,oldResolve=Dispatch.resolveApplicationUseTarget,oldEnd=Dispatch.endAuthenticatedTurn
        defer{Dispatch.nativeUsage=oldRuntime;Dispatch.checkApplicationPolicy=oldPolicy;Dispatch.checkGlobalConfiguration=oldGlobal
            Dispatch.prepareAuthenticatedRequest=oldPrepare;Dispatch.ensureSystemPermissions=oldPermissions;Dispatch.requestActivity=oldActivity
            Dispatch.onApplicationUsed=oldUsed;Dispatch.resolveApplicationUseTarget=oldResolve;Dispatch.endAuthenticatedTurn=oldEnd}
        let trace=NativeDispatchTrace(),world=NativeDispatchWorld(trace:trace);world.install()
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ value:Bool){checks.append(["name":name,"passed":value]);if !value{print("FAIL: "+name)}}
        let thread="owned-C130-"+UUID().uuidString
        func request(_ type:DirectRequestType,_ body:String,socket:Bool,turn:String="native",node:Bool=false,cancel:NativeDispatchCancel?=nil)async->NativeDispatchReply {
            let runtime=Dispatch.nativeUsage
            return await withCheckedContinuation{continuation in DispatchQueue.global().async {
                var sender=SenderRequestContext(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[])
                sender.clientMetadata = .init(clientType:node ? .nodeRepl:nil,mcpRuntime:.nodeRepl)
                let metadata=ComputerUseJSONRPCCodexTurnMetadata(sessionID:thread,turnID:turn)
                do {
                    if socket {
                        let object=try JSONSerialization.jsonObject(with:Data(body.utf8))
                        let message:JSON=["id":1,"jsonrpc":"2.0","method":"request","params":["clientApiVersion":kApiVersion,"requestType":type.rawValue,"request":object,"agentTurnMetadata":try JSONSerialization.jsonObject(with:JSONEncoder().encode(metadata))]]
                        let response=Dispatch.handle(message,cancelled:{cancel?.value ?? false},peerPID:getpid(),senderContext:sender)
                        let error=response["error"] as? [String:Any]
                        continuation.resume(returning:.init(data:try JSONSerialization.data(withJSONObject:response),code:error?["code"] as? Int,message:error?["message"] as? String))
                    }else{
                        let data=try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:type.rawValue,request:Data(body.utf8),metadata:JSONEncoder().encode(metadata),files:[],senderContext:sender,cancelled:{cancel?.value ?? false})
                        continuation.resume(returning:.init(data:data,code:nil,message:nil))
                    }
                }catch{let error=ComputerUseXPC.requestError(error);continuation.resume(returning:.init(data:nil,code:error.code,message:error.localizedDescription))}
                withExtendedLifetime(runtime){}
            }}
        }
        for socket in [false,true] {
            let before=trace.phases.count
            let started=await request(.appStart,#"{"app":"owned-native"}"#,socket:socket)
            check("ordinary \(socket ? "socket":"XPC") start reaches native canonical manager",started.code==nil && world.fixture.bindings.manager.instance(for:world.fixture.target.identifier)?.controller.owner.isActive==true && world.factoryCalls==1)
            let shot=await request(.appGetAppSnapshot,#"{"app":"owned-native","disableDiff":true}"#,socket:socket)
            check("ordinary \(socket ? "socket":"XPC") appSnapshot reaches native reply formatter",shot.code==nil && String(data:shot.data!,encoding:.utf8)!.contains("owned capture result"))
            let action=await request(.appPerformAction,#"{"app":"owned-native","action":{"type":{"_0":"owned"}}}"#,socket:socket,node:true)
            check("ordinary \(socket ? "socket":"XPC") action uses sender node capture selection",action.code==nil && trace.phases.contains("action:type:false"))
            let scopeRows=Array(trace.rows.dropFirst(before)).filter{($0["phase"] as? String)?.hasPrefix("state:")==true || ($0["phase"] as? String)?.hasPrefix("action:")==true}
            check("worker request identity and task metadata survive async native queue \(socket)",!scopeRows.isEmpty && scopeRows.allSatisfy{$0["thread"] as? String==thread && $0["turn"] as? String=="native" && $0["peer"] as? Int32==getpid() && $0["sender"] as? Int32==getpid()})
            check("ordinary native completion re-resolves canonical app before tracking use \(socket)",trace.phases.suffix(2)==["resolve:owned-native","used:"+world.fixture.target.identifier])
            let missing=await request(.appGetAppSnapshot,#"{"app":"owned-missing"}"#,socket:socket)
            check("native missing-target error uses transport-specific payload \(socket)",missing.code == -10010 && missing.message==(socket ? "Invalid app: owned-missing":"owned-missing"))
            let blocked=await request(.appPerformAction,#"{"app":"owned-native","action":{"type":{"_0":"owned blocked"}}}"#,socket:socket)
            let expected=ControllerNativeMappedError(code:.blockedURL,payload:"https://EXAMPLE.invalid/a?q=1#f")
            check("native URL rejection keeps raw XPC URL and mapped socket description \(socket)",blocked.code == -10015 && blocked.message==(socket ? expected.socketDescription:expected.payload))
        }
        let target=world.fixture.target.identifier
        let stopBody=String(data:try JSONSerialization.data(withJSONObject:["app":target]),encoding:.utf8)!
        let stopped=await request(.appStop,stopBody,socket:false)
        check("ordinary stop removes native instance and keeps stopped marker",stopped.code==nil && world.fixture.bindings.manager.instance(for:target)==nil && world.fixture.bindings.manager.wasStoppedByUser(for:target))
        let refused=await request(.appGetAppSnapshot,#"{"app":"owned-native"}"#,socket:false)
        check("ordinary native stopped-state error retains caller alias payload",refused.code == -10012 && refused.message=="owned-native")
        let endedBody=String(data:try JSONSerialization.data(withJSONObject:["threadID":thread,"turnID":"native"]),encoding:.utf8)!
        let ended=await request(.agentTurnEnded,endedBody,socket:false,turn:"ending")
        check("ordinary end-of-turn tracking clears same native canonical stopped marker",ended.code==nil && !world.fixture.bindings.manager.wasStoppedByUser(for:target))
        let renewed=await request(.appGetAppSnapshot,#"{"app":"owned-native"}"#,socket:true,turn:"next")
        check("new turn can prepare a fresh native instance after stop reset",renewed.code==nil && world.fixture.bindings.manager.instance(for:target) != nil)
        let gate=NativeDispatchGate(),cancel=NativeDispatchCancel();world.gate=gate
        let held=Task{await request(.appPerformAction,#"{"app":"owned-native","action":{"type":{"_0":"owned wait"}}}"#,socket:false,turn:"next",node:true,cancel:cancel)}
        await gate.wait();cancel.set();let cancelled=await held.value
        check("connection cancellation reaches worker while native instance job is awaiting",cancelled.code == -10005 && cancelled.message=="Request cancelled")
        await gate.finish()
        for _ in 0..<100 where !trace.phases.contains("action.released"){await Task.yield()}
        check("cancelling waiter does not cancel or skip native instance job",trace.phases.contains("action.released"))
        let finished=await request(.appModify,#"{"app":"owned-native","modification":{"deactivate":{}}}"#,socket:true,turn:"next")
        check("subsequent native queue job completes after cancelled waiter",finished.code==nil && world.fixture.bindings.manager.instance(for:target)==nil)
        await world.fixture.finish()
        check("native bridge request scope and telemetry do not escape caller",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil && ComputerUseTelemetryContext.snapshot().isEmpty)
        let errors:[(Error,CUErrorCode,String)]=[
            (ControllerInstanceResolutionError.noInstance("alias"),.noActiveSession,"alias"),
            (ControllerInstanceResolutionError.stoppedByUser("alias"),.userStoppedSession,"alias"),
            (ControllerNativeApplicationLifecycleError.forbiddenTarget("bundle"),.appNotAllowed,"bundle"),
            (ControllerNativeElementDecoding.Failure.accessibility(-25204),.accessibilityError,"-25204"),
            (ComputerUseControllerIdentityError.runningApplicationNotFound("bundle"),.runningApplicationNotFound,"bundle"),
            (ControllerCoordinateTargetFailure.noWindows,.unknownError,"noWindowsAvailable")]
        for (error,code,payload) in errors {
            let mapped=ControllerNativeMappedError.classify(error),native=ComputerUseXPC.requestError(mapped)
            check("classifier envelope \(code.rawValue)",mapped.code==code && mapped.payload==payload && native.domain=="ComputerUseIPCXPC" && native.code==code.rawValue && native.localizedDescription==payload)
        }
        check("AX status uses AXError debug-description mapping",ControllerNativeMappedError(code:.accessibilityError,payload:"-25204").socketDescription=="Accessibility error: AXError.cannotComplete")
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,"trace":trace.rows,
            "ordinary_socket_and_XPC_dispatch_selected_native_manager":true,"actual_native_effects_intercepted":true,"physical_input_focus_capture_or_preferences":false,
            "full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native ordinary service dispatch: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
