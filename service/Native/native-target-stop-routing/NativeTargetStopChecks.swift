import AppKit
import Foundation

@MainActor private final class ResolverFixture {
    var trace: [String] = []
    var paths: [String:String] = [:], bundles: [URL:String] = [:]
    var installed: [URL] = [], running: [URL] = [], name: String?, onURLRead: ((URL)->Void)?
    var canonical: [URL:URL] = [:]
    var resolver: ControllerApplicationTargetResolver {
        .init(environment:.init(bundleIdentifierAtPath:{ self.trace.append("path:"+$0);return self.paths[$0] },
            bundleIdentifierAtURL:{ self.trace.append("metadata:"+$0.lastPathComponent);self.onURLRead?($0);return self.bundles[$0] },
            canonicalURL:{ self.trace.append("canonical:"+$0.lastPathComponent);return self.canonical[$0] ?? $0.standardizedFileURL },
            installedURLs:{ self.trace.append("installed:"+$0);return self.installed },
            runningURLs:{ self.trace.append("running:"+$0);return self.running },
            pathForName:{ self.trace.append("name:"+$0);return self.name }))
    }
}
private actor StopQueueGate {
    private var entered = false, release: CheckedContinuation<Void,Never>?
    func hold() async { entered = true;await withCheckedContinuation { release = $0 } }
    func wait() async { while !entered { await Task.yield() } }
    func finish() { release?.resume();release = nil }
}

@MainActor enum NativeTargetStopChecks {
    static func run(output: URL,directory: URL) async throws -> Int32 {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks: [[String:Any]] = []
        func check(_ name: String,_ passed: Bool) { checks.append(["name":name,"passed":passed]);if !passed { print("FAIL: "+name) } }
        let a=URL(fileURLWithPath:"/private/tmp/C129 A.app"),b=URL(fileURLWithPath:"/private/tmp/C129 B.app"),alias=URL(fileURLWithPath:"/private/tmp/C129 Alias.app")
        do {
            let f=ResolverFixture();f.paths[a.path]="actual.id";f.canonical[a]=b
            let result=try f.resolver.resolve(a.path)
            check("direct bundle path wins without installed/running/name lookup",result.bundleIdentifier=="actual.id" && result.url==b && f.trace==["path:"+a.path,"canonical:"+a.lastPathComponent])
        }
        do {
            let f=ResolverFixture();f.installed=[a,b,alias];f.running=[b];f.canonical[alias]=a;f.bundles[a]="id";f.bundles[b]="id"
            let targets=f.resolver.applicationTargets(bundleIdentifier:"id")
            check("running targets precede installed and canonical aliases are deduplicated",targets.map(\.url)==[b,a])
            check("installed URL acquisition precedes running metadata and running is revalidated",f.trace.prefix(2)==["installed:id","running:id"] && f.trace.filter{$0=="metadata:"+b.lastPathComponent}.count==3)
            var ambiguous=false
            do {_ = try f.resolver.resolve("id")}
            catch ControllerApplicationTargetLookupError.ambiguous(let query,let paths) {ambiguous=query=="id" && paths==[a.path,b.path]}
            check("ambiguous identifier sorts canonical paths and skips name fallback",ambiguous && !f.trace.contains("name:id"))
        }
        do {
            let f=ResolverFixture();f.installed=[a,b];f.bundles[a]="ID";f.bundles[b]="id"
            let result=try f.resolver.resolve("id")
            check("bundle metadata equality is case sensitive",result.url==b && result.bundleIdentifier=="id")
        }
        do {
            let f=ResolverFixture();f.installed=[a];f.bundles[a]="other";f.name=b.path;f.paths[b.path]="named.bundle"
            let result=try f.resolver.resolve("query")
            check("invalid registered metadata permits fullPath name fallback and retains actual bundle identifier",result.url==b && result.bundleIdentifier=="named.bundle" && f.trace.suffix(3)==["name:query","path:"+b.path,"canonical:"+b.lastPathComponent])
        }
        for query in [""," id ","ID","unknown"] {
            let f=ResolverFixture();var invalid=false
            do {_ = try f.resolver.resolve(query)}catch ControllerApplicationTargetLookupError.invalid(let raw){invalid=raw==query}
            check("missing target preserves exact query without trimming \(query)",invalid && f.trace.first=="path:"+query && f.trace.last=="name:"+query)
        }
        do {
            let f=ResolverFixture();f.running=[a];f.installed=[b];f.bundles[a]="id";f.bundles[b]="id"
            var reads=0;f.onURLRead={url in if url==a{reads+=1;if reads==2{f.bundles[a]="changed"}}}
            let target=try f.resolver.resolve("id")
            check("second metadata validation rejects a changed running bundle before final selection",target.url==b && reads==2)
        }
        check("invalid target description keeps its prefix",ControllerApplicationTargetLookupError.invalid("x").description=="Invalid app: x")
        check("ambiguity description keeps its exact guidance",ControllerApplicationTargetLookupError.ambiguous("id",["a","b"]).description=="Ambiguous app identifier 'id'. Multiple apps share this bundle identifier: a, b. Use an app name or full app path instead.")
        try nativeResolver(directory:directory,check:check)
        try await facade(check:check)
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,"actual_native_bundle_and_workspace_lookup":true,
            "native_manager_stop_and_typed_five_route_facade_executed":true,"input_focus_capture_or_general_clipboard":false,
            "ordinary_transport_native_routes_selected":false,"full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native target/stop/facade: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
    private static func nativeResolver(directory: URL,check:(String,Bool)->Void) throws {
        let actual=directory.appendingPathComponent("Owned %.bundle"),link=directory.appendingPathComponent("Alias.bundle")
        try FileManager.default.createDirectory(at:actual.appendingPathComponent("Contents"),withIntermediateDirectories:true)
        let bundle="local.cua.C129."+UUID().uuidString
        let plist:[String:Any]=["CFBundleIdentifier":bundle,"CFBundleName":"Owned C129","CFBundlePackageType":"BNDL"]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:actual.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:actual)
        let env=ControllerApplicationTargetResolver.Environment.native(),native=ControllerApplicationTargetResolver(environment:env)
        let direct=try native.resolve(actual.path),aliased=try native.resolve(link.path)
        check("native Bundle path lookup accepts a non-application bundle",direct.bundleIdentifier==bundle && direct.identifier==ComputerUseApplicationTarget.identifier(for:actual))
        check("native symlink path produces same canonical target and decoded percent path",direct.identifier==aliased.identifier && direct.bundleIdentifier==aliased.bundleIdentifier && direct.identifier.contains("Owned %.bundle"))
        check("native resolver preserves Foundation URL value while canonical session identifiers agree",direct.url != aliased.url && direct.identifier==aliased.identifier)
        let finder=try native.resolve("Finder"),byPath=try native.resolve(finder.url.path)
        check("native fullPath selector resolves installed app name",finder.bundleIdentifier=="com.apple.finder" && finder==byPath)
        let byID=try native.resolve("com.apple.finder")
        check("native bundle identifier lookup resolves same installed target",byID==finder)
        var rejected=false
        do{_ = try native.resolve(bundle+".missing")}catch ControllerApplicationTargetLookupError.invalid(let query){rejected=query==bundle+".missing"}
        check("native unavailable identifier returns typed failure with the requested query",rejected)
    }
    private static func facade(check:(String,Bool)->Void) async throws {
        let f=LifecycleFixture();var resolution:[String]=[],effects:[String]=[]
        let resolver=ControllerApplicationTargetResolver(environment:.init(bundleIdentifierAtPath:{ query in
            resolution.append(query);return ["owned alias","other alias"].contains(query) ? f.target.bundleIdentifier:nil
        },bundleIdentifierAtURL:{_ in nil},canonicalURL:{_ in f.target.url},installedURLs:{_ in []},runningURLs:{_ in []},pathForName:{_ in nil}))
        let stateEnv=ControllerNativeAppSnapshotRequestEnvironment(capture:{_,_ in effects.append("capture");return try NativeSecondaryScrollDataAppSnapshotBindingChecks.result(f.data)},
            blockedURL:{_,_ in nil},scheduleFinished:{_ in effects.append("finished")},instructions:{_ in "owned"})
        let actionEnv=ControllerNativeActionRequestEnvironment(focus:{_ in effects.append("focus")},activity:{_,value in effects.append("activity\(value)")},
            dispatch:{_,_,_ in effects.append("action");return nil},blockedURL:{_,_ in preconditionFailure("No capture policy")})
        let service=ControllerNativeServiceFacade(lifecycle:f.lifecycle,resolver:resolver,appSnapshotEnvironment:stateEnv,actionEnvironment:actionEnv)
        func call(_ type:DirectRequestType,_ body:String)async throws->Data{try await service.handle(type:type.rawValue,body:Data(body.utf8),sender:nil)}
        let start=try JSONDecoder().decode(IPCAppState.self,from:await call(.appStart,#"{"app":"owned alias"}"#))
        let instance=f.bindings.manager.instance(for:f.target.identifier)!
        check("typed start resolves canonical target before launch and returns native app state",start.active && start.currentApp?.pid==getpid() && f.configurations.count==1)
        _ = try await call(.appGetAppSnapshot,#"{"app":"other alias","disableDiff":true}"#)
        check("typed appSnapshot alias shares the canonical native owner",f.bindings.manager.instance(for:f.target.identifier)===instance && f.configurations.count==1 && effects==["capture","finished"])
        let action=try await call(.appPerformAction,#"{"app":"owned alias","action":{"type":{"_0":"owned"}}}"#)
        let normalized=try SocketResponseBody.normalizeData(action,for:DirectRequestType.appPerformAction.rawValue) as! [String:Any]
        check("typed action decodes existing wire enum and reaches same native instance",effects.suffix(4)==["focus","activity0","action","activity1"] && normalized["appSnapshot"]==nil && f.configurations.count==1)
        _ = try await call(.appModify,#"{"app":"owned alias","modification":{"activate":{}}}"#)
        check("typed modification reaches same controller without relaunch",f.bindings.manager.instance(for:f.target.identifier)===instance && f.trace.values.filter{$0=="launch"}.count==2)
        let before=resolution.count
        let aliasStop=try JSONDecoder().decode(IPCAppState.self,from:await call(.appStop,#"{"app":"owned alias"}"#))
        check("raw alias stop records alias reason without resolving or stopping canonical owner",!aliasStop.active && aliasStop.currentApp==nil && resolution.count==before && f.bindings.manager.wasStoppedByUser(for:"owned alias") && instance.controller.owner.isActive)
        let gate=StopQueueGate()
        let preceding=Task{try await instance.serialExecutor.execute{await gate.hold()}}
        await gate.wait()
        var stopFinished=false
        let stop=Task{@MainActor in let state=try await service.lifecycle.stop(f.target.identifier);stopFinished=true;return state}
        for _ in 0..<100 where !f.bindings.manager.wasStoppedByUser(for:f.target.identifier){await Task.yield()}
        check("canonical stop marks stopped immediately while waiting behind existing work",f.bindings.manager.wasStoppedByUser(for:f.target.identifier) && !stopFinished && instance.controller.owner.isActive)
        await gate.finish();_ = try await preceding.value;let stopped=try await stop.value
        check("native stop waits queue, deactivates and removes owner but preserves stopped reason",stopFinished && !stopped.active && stopped.currentApp?.bundleIdentifier==f.target.bundleIdentifier && f.bindings.manager.instance(for:f.target.identifier)==nil && f.bindings.manager.wasStoppedByUser(for:f.target.identifier) && !instance.controller.owner.isActive)
        let encoded=try JSONEncoder().encode(stopped),normalizedStop=try SocketResponseBody.normalizeData(encoded,for:DirectRequestType.appStop.rawValue) as! [String:Any]
        check("native stopped response passes actual socket schema with retained app identity",normalizedStop["active"] as? Bool==false && normalizedStop["currentApp"] is [String:Any])
        let unknown=try await service.lifecycle.stop("")
        check("empty raw stop identifier is recorded without fabricated current app",unknown.currentApp==nil && !unknown.active && f.bindings.manager.wasStoppedByUser(for:""))
        f.bindings.manager.clearStoppedByUser(for:f.target.identifier)
        _ = try await call(.appStart,#"{"app":"owned alias"}"#)
        _ = try await call(.appModify,#"{"app":"owned alias","modification":{"deactivate":{}}}"#)
        check("deactivation removes session without setting canonical stopped reason",f.bindings.manager.instance(for:f.target.identifier)==nil && !f.bindings.manager.wasStoppedByUser(for:f.target.identifier))
        let previous=resolution.count;var malformed=false
        do{_ = try await call(.appStart,#"{"app":4}"#)}catch is DecodingError{malformed=true}
        check("typed facade rejects malformed body before target lookup or native effects",malformed && resolution.count==previous)
        var unsupported=false
        do{_ = try await service.handle(type:DirectRequestType.listApps.rawValue,body:Data("{".utf8),sender:nil)}
        catch ControllerNativeServiceFacadeError.unsupportedRoute(let type){unsupported=type==DirectRequestType.listApps.rawValue}
        check("facade limits itself to five native usage routes before decoding unknown route",unsupported && !ControllerNativeServiceFacade.supports(DirectRequestType.listApps.rawValue))
        for type in [DirectRequestType.appStart,.appStop,.appModify,.appGetAppSnapshot,.appPerformAction]{check("native facade supports \(type.rawValue)",ControllerNativeServiceFacade.supports(type.rawValue))}
        await f.finish()
    }
}
