import AppKit
import ApplicationServices
import Foundation

/// Configured before dispatch; only one owned worker accesses each world.
private final class FrontmostWorld:@unchecked Sendable {
    struct App:Sendable {var bundle:String?;var name:String?;var regular=true;var hidden=false;var window:Int32?}
    var apps:[Int32:App]=[
        1:.init(bundle:"owned.service",name:"Service",window:100),2:.init(bundle:"owned.peer",name:"Peer",window:200),
        3:.init(bundle:"owned.responsible",name:"Responsible",window:300),4:.init(bundle:"owned.parent",name:"Parent",window:400),
        5:.init(bundle:"owned.other",name:"Other",window:500),6:.init(bundle:"owned.hidden",name:"Hidden",hidden:true,window:600),
        7:.init(bundle:"owned.accessory",name:"Accessory",regular:false,window:700),8:.init(bundle:nil,name:"Missing",window:800),
        9:.init(bundle:"",name:"Empty",window:900),10:.init(bundle:"owned.second",name:"Second",window:1000)]
    var current:Int32?=5,pids:[Int32]=[2,3,5],titles:[Int32:String]=[100:"Service title",200:"Peer title",300:"Responsible title",400:"Parent title",500:"Other title",600:"Hidden title",700:"Accessory title",800:"Missing title",900:"Empty title",1000:"Second title"]
    var bundleReads:[Int32:[String?]]=[:]
    var trace:[String]=[]
    var environment:ControllerFrontmostWindow<Int32,Int32>.Environment {
        .init(runningApplication:{id in self.trace.append("running:\(id)");return self.apps[id] == nil ? nil:id},
            bundleIdentifier:{id in
                self.trace.append("bundle:\(id)")
                if var values=self.bundleReads[id],!values.isEmpty {let value=values.removeFirst();self.bundleReads[id]=values;return value}
                return self.apps[id]?.bundle
            },frontmostApplication:{self.trace.append("frontmost");return self.current},matchingWindowPIDs:{self.trace.append("pids");return self.pids},
            isRegular:{id in self.trace.append("regular:\(id)");return self.apps[id]?.regular==true},
            isHidden:{id in self.trace.append("hidden:\(id)");return self.apps[id]?.hidden==true},
            applicationNode:{id in self.trace.append("application:\(id)");return id},primaryWindow:{id in self.trace.append("primary:\(id)");return self.apps[id]?.window},
            localizedName:{id in self.trace.append("name:\(id)");return self.apps[id]?.name},windowTitle:{id in self.trace.append("title:\(id)");return self.titles[id]})
    }
}
@MainActor enum NativeFrontmostWindowChecks {
    private typealias Value=ControllerFrontmostWindowResult
    private struct Reply:Sendable {let data:Data?;let error:String?;let worker:Bool}
    nonisolated private static func request(_ world:FrontmostWorld,_ sender:SenderRequestContext?)->Reply {
            do {
                let data=try RequestRuntime.withRequest([:],peerPID:2,senderContext:sender){
                    let value=try AppLifecycle.frontmostWindow(environment:world.environment)
                    return try JSONSerialization.data(withJSONObject:value as Any? ?? NSNull(),options:[.fragmentsAllowed])
                }
                return .init(data:data,error:nil,worker:!Thread.isMainThread)
            }catch{return .init(data:nil,error:String(describing:error),worker:!Thread.isMainThread)}
        }
    static func run(output:URL)async throws->Int32 {
        var checks:[[String:Any]]=[],observations:[[String:Any]]=[]
        func check(_ name:String,_ value:Bool){checks.append(["name":name,"passed":value]);if !value{print("FAIL: "+name)}}
        let sender=SenderRequestContext(senderPID:2,responsibleIdentity:.init(bundleID:"owned.responsible"),ancestorIdentities:[.init(bundleID:"owned.parent")])
        let peerOnly=SenderRequestContext(senderPID:2,responsibleIdentity:nil,ancestorIdentities:[.init(bundleID:"owned.parent")])
        func result(_ id:Int32,_ world:FrontmostWorld)->Value? {
            guard let app=world.apps[id],let bundle=app.bundle,!bundle.isEmpty,let window=app.window else{return nil}
            return .init(bundleIdentifier:bundle,name:app.name ?? bundle,windowTitle:world.titles[window])
        }
        func run(_ name:String,sender:SenderRequestContext?=nil,configure:(FrontmostWorld)->Void={_ in},expected:(FrontmostWorld)->Value?,traceValid:(FrontmostWorld)->Bool={_ in true})async throws {
            let world=FrontmostWorld();configure(world);let want=expected(world)
            let reply:Reply=await withCheckedContinuation{continuation in DispatchQueue.global(qos:.userInitiated).async{continuation.resume(returning:Self.request(world,sender))}}
            let value=try reply.data.map{try JSONDecoder().decode(Value?.self,from:$0)} ?? nil
            let valid=reply.error==nil && reply.worker && value==want && traceValid(world)
            check(name,valid)
            observations.append(["name":name,"worker":reply.worker,"error":reply.error as Any? ?? NSNull(),"trace":world.trace,
                "value":try value.map{try JSONSerialization.jsonObject(with:JSONEncoder().encode($0))} ?? NSNull(),
                "expected":try want.map{try JSONSerialization.jsonObject(with:JSONEncoder().encode($0))} ?? NSNull()])
            if !valid{print(world.trace);print(String(describing:value))}
        }
        try await run("no sender excludes neither peer bundle nor PID",configure:{$0.current=2},expected:{result(2,$0)},traceValid:{!$0.trace.contains("running:2")})
        try await run("present sender excludes responsible and sender bundle",sender:sender,configure:{$0.current=2},expected:{result(5,$0)})
        try await run("parent identity is not a bundle exclusion",sender:sender,configure:{$0.current=4},expected:{result(4,$0)})
        try await run("absent responsible identity contributes no exclusion",sender:peerOnly,configure:{$0.current=3},expected:{result(3,$0)})
        try await run("missing sender process is tolerated",sender:peerOnly,configure:{$0.apps.removeValue(forKey:2)},expected:{result(5,$0)})
        try await run("fast path permits service app when bundle is not excluded",configure:{$0.current=1},expected:{result(1,$0)})
        try await run("fast path does not add a hidden-app filter",configure:{$0.current=6},expected:{result(6,$0)})
        try await run("fast path does not add an activation-policy filter",configure:{$0.current=7},expected:{result(7,$0)})
        try await run("nil current application uses ordered fallback",configure:{$0.current=nil;$0.pids=[5,10]},expected:{result(5,$0)})
        try await run("current nil bundle uses fallback",configure:{$0.current=8;$0.pids=[5]},expected:{result(5,$0)})
        try await run("current empty bundle returns nil without fallback",configure:{$0.current=9},expected:{_ in nil},traceValid:{!$0.trace.contains("pids")})
        try await run("fallback skips nil bundle hidden and nonregular applications",sender:sender,configure:{$0.current=nil;$0.pids=[8,6,7,2,3,5]},expected:{result(5,$0)})
        try await run("fallback empty bundle is selected then rejected by handler",configure:{$0.current=nil;$0.pids=[9,5]},expected:{_ in nil},traceValid:{$0.trace.contains("bundle:5") && !$0.trace.contains(where:{$0.hasPrefix("primary:")})})
        try await run("empty fallback returns nil",configure:{$0.current=nil;$0.pids=[]},expected:{_ in nil})
        try await run("fallback with only excluded applications returns nil",sender:sender,configure:{$0.current=nil;$0.pids=[2,3]},expected:{_ in nil})
        try await run("all PID mappings precede all fallback property filters",configure:{$0.current=nil;$0.pids=[5,5,10]},expected:{result(5,$0)},traceValid:{w in
            guard let last=w.trace.lastIndex(of:"running:10"),let first=w.trace.firstIndex(of:"bundle:5") else{return false}
            return last<first && w.trace.filter{$0=="running:5"}.count==2 && w.trace.contains("bundle:10")
        })
        try await run("fallback rechecks selected bundle and does not advance to second",sender:peerOnly,configure:{$0.current=nil;$0.pids=[5,10];$0.bundleReads[5]=["owned.other","owned.peer"]},expected:{_ in nil})
        try await run("fallback selected bundle becoming nil returns nil",configure:{$0.current=nil;$0.pids=[5,10];$0.bundleReads[5]=["owned.other",nil]},expected:{_ in nil})
        try await run("handler reread does not invent a third exclusion check",sender:peerOnly,configure:{$0.current=nil;$0.pids=[5];$0.bundleReads[5]=["owned.other","owned.other","owned.peer"]},expected:{w in .init(bundleIdentifier:"owned.peer",name:"Other",windowTitle:w.titles[500])})
        try await run("missing localized name falls back to selected bundle",configure:{$0.apps[5]?.name=nil},expected:{result(5,$0)})
        try await run("empty localized name is preserved",configure:{$0.apps[5]?.name=""},expected:{result(5,$0)})
        try await run("missing primary still reads localized name then returns nil",configure:{$0.apps[5]?.window=nil},expected:{_ in nil},traceValid:{$0.trace.contains("name:5") && !$0.trace.contains("title:500")})
        try await run("missing title remains optional",configure:{$0.titles.removeValue(forKey:500)},expected:{result(5,$0)})
        try await run("empty title is preserved",configure:{$0.titles[500]=""},expected:{result(5,$0)})
        var levelReads=0,pidReads=0
        let rows:[[AnyHashable:Any]]=[
            [kCGWindowNumber as String:UInt32(1),kCGWindowOwnerPID as String:Int32(1),kCGWindowLayer as String:Int32(0)],
            [kCGWindowNumber as String:UInt32(2),kCGWindowOwnerPID as String:Int32(2),kCGWindowLayer as String:Int32(20)],
            [kCGWindowNumber as String:UInt32(3),kCGWindowOwnerPID as String:Int32(3),kCGWindowLayer as String:Int32(-1)],
            [kCGWindowNumber as String:UInt32(4)]]
        let pids=ControllerFrontmostWindowNative.matchingWindowPIDs(rows,menuLevel:{levelReads+=1;return 20},currentPID:{pidReads+=1;return 1})
        check("native CGWindow decoder defaults and per-row menu/own-PID filtering",pids==[3,-1] && levelReads==4 && pidReads==3)
        let source=FrontmostWorld();source.titles.removeValue(forKey:500)
        let encoded=try JSONEncoder().encode(ControllerFrontmostWindow<Int32,Int32>(environment:source.environment).read(sender:nil))
        let keys=(try JSONSerialization.jsonObject(with:encoded) as? JSON)?.keys.sorted()
        check("optional title is omitted from typed wire result",keys==["bundleIdentifier","name"])
        let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--native-frontmost-malformed-window"]
        child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice;child.environment=ProcessInfo.processInfo.environment.merging(["SWIFT_BACKTRACE":"disable"]){_,new in new}
        try child.run();let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while child.isRunning && ContinuousClock.now<deadline{try await Task.sleep(for:.milliseconds(10))}
        let exceeded=child.isRunning
        if exceeded{_ = kill(child.processIdentifier,SIGKILL)}
        child.waitUntilExit()
        check("native fallback eagerly decodes mandatory IDs even for later rows",!exceeded && child.terminationReason == .uncaughtSignal && child.terminationStatus != 0)
        check("request sender scope restored after owned frontmost calls",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        let report:[String:Any]=["passed":passed,"checks":checks,"observations":observations,"actual_AppLifecycle_frontmost_method_with_owned_native_dependencies":true,"default_native_environment_compile_verified":true,"actual_default_frontmost_AX_result_accepted":false,"ordinary_frontmost_transport_runtime_accepted":false,"input_capture_focus_or_general_clipboard":false,"all_owned_workers_and_child_terminal":!child.isRunning,"full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native frontmost window: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
