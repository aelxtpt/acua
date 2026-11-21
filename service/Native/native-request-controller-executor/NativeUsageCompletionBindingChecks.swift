import AppKit
import Foundation

private final class UsageCompletionWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var currentMode = "good"
    private var recorded = [(String,ComputerUseTelemetryContext.Snapshot)]()
    let file: URL?
    init(file: URL? = nil) { self.file = file }
    var mode: String { get { lock.withLock { currentMode } } set { lock.withLock { currentMode = newValue; recorded.removeAll() } } }
    var events: [String] { lock.withLock { recorded.map(\.0) } }
    var snapshots: [ComputerUseTelemetryContext.Snapshot] { lock.withLock { recorded.map(\.1) } }
    func event(_ kind: String, value: String) {
        let metadata = ComputerUseTelemetryContext.snapshot()
        lock.withLock {
            recorded.append((kind,metadata))
            guard let file else { return }
            let row: [String:Any] = ["phase":kind,"value":value,"session":metadata.agentSessionID as Any? ?? NSNull(),"turn":metadata.agentTurnID as Any? ?? NSNull()]
            var bytes = try! JSONSerialization.data(withJSONObject: row,options:.sortedKeys); bytes.append(10)
            if !FileManager.default.fileExists(atPath:file.path) { _ = FileManager.default.createFile(atPath:file.path,contents:Data()) }
            let handle = try! FileHandle(forWritingTo:file); try! handle.seekToEnd(); try! handle.write(contentsOf:bytes); try! handle.close()
        }
    }
    func response(_ app: String) throws -> Any {
        event("handler",value:app)
        let mode = file == nil ? self.mode : ComputerUseTelemetryContext.snapshot().agentTurnID ?? "good"
        if mode == "handler-fail" { throw ServiceError(.invalidApp,"owned-handler-error") }
        if mode == "encode-fail" || mode == "usage-encode-fail" { return ["active":Date()] }
        if mode == "conversion-fail" || mode == "usage-conversion-fail" { return ["active":"invalid"] }
        return ["active":true,"currentApp":["pid":getpid(),"bundleIdentifier":"owned.C115.app","appPath":"/owned/canonical.app"],"future":"native-only"] as [String:Any]
    }
    func resolve(_ app: String) throws -> String {
        event("resolve",value:app)
        if mode == "resolve-fail" || ComputerUseTelemetryContext.snapshot().agentTurnID == "usage-resolve-fail" { throw ServiceError(.invalidApp,"owned-post-lookup-error") }
        return "/owned/canonical.app"
    }
    func install() {
        Dispatch.performAppStart = response
        Dispatch.resolveApplicationUseTarget = resolve
        Dispatch.onApplicationUsed = { self.event("used",value:$0) }
    }
}
private struct UsageCompletionReply: Sendable { let data: Data?; let code: Int?; let message: String?; let serializationFailed: Bool }
@MainActor enum NativeUsageCompletionBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        let oldStart = Dispatch.performAppStart, oldResolve = Dispatch.resolveApplicationUseTarget, oldUsed = Dispatch.onApplicationUsed
        let oldPrepare = Dispatch.prepareAuthenticatedRequest, oldPermission = Dispatch.ensureSystemPermissions
        let oldApp = Dispatch.checkApplicationPolicy, oldPower = Dispatch.requestActivity
        defer { Dispatch.performAppStart=oldStart;Dispatch.resolveApplicationUseTarget=oldResolve;Dispatch.onApplicationUsed=oldUsed
            Dispatch.prepareAuthenticatedRequest=oldPrepare;Dispatch.ensureSystemPermissions=oldPermission
            Dispatch.checkApplicationPolicy=oldApp;Dispatch.requestActivity=oldPower }
        var cases = [[String:Any]]()
        func check(_ name: String,_ value: Bool) { cases.append(["name":name,"passed":value]);if !value { print("FAIL: "+name) } }
        check("actual default completion resolver returns installed canonical application path",try oldResolve("/System/Library/CoreServices/Finder.app") == "/System/Library/CoreServices/Finder.app")
        let world = UsageCompletionWorld();world.install()
        Dispatch.prepareAuthenticatedRequest={_,_ in};Dispatch.ensureSystemPermissions={_,_ in .granted};Dispatch.checkApplicationPolicy={_ in}
        Dispatch.requestActivity = .init(provider:.init(create:{_,id in id=0;return 0},release:{_ in 0}))
        let metadata = ComputerUseJSONRPCCodexTurnMetadata(model:"owned",reasoningEffort:"high",sessionID:"owned-C115",turnID:"usage",turnStartedAtUnixMilliseconds:5,userInputRequestedDuringTurn:false)
        let bytes = try JSONEncoder().encode(metadata), snapshot = ComputerUseTelemetryContext.Snapshot(metadata)
        func request(socket: Bool) async -> UsageCompletionReply {
            await withCheckedContinuation { continuation in DispatchQueue.global().async {
                do {
                    if socket {
                        var failed = false
                        let reply=Dispatch.handle(["id":1,"jsonrpc":"2.0","method":"request","params":["clientApiVersion":kApiVersion,"requestType":"ComputerUseIPCAppStartRequest","request":["app":"owned-alias"],"agentTurnMetadata":try JSONSerialization.jsonObject(with:bytes)]],serializationFailed:{_ in failed=true})
                        let error=reply["error"] as? [String:Any]
                        continuation.resume(returning:.init(data:try JSONSerialization.data(withJSONObject:reply),code:error?["code"] as? Int,message:error?["message"] as? String,serializationFailed:failed))
                    } else {
                        let data=try Dispatch.handleXPC(peer:.init(pid:getpid(),uid:getuid(),auditToken:Data()),type:"ComputerUseIPCAppStartRequest",request:Data(#"{"app":"owned-alias"}"#.utf8),metadata:bytes,files:[],senderContext:.init(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[]),cancelled:{false})
                        continuation.resume(returning:.init(data:data,code:nil,message:nil,serializationFailed:false))
                    }
                } catch let error as ServiceError { continuation.resume(returning:.init(data:nil,code:error.code.rawValue,message:error.message,serializationFailed:false)) }
                catch { continuation.resume(returning:.init(data:nil,code:nil,message:String(describing:error),serializationFailed:false)) }
            } }
        }
        let native = await request(socket:false)
        let nativeJSON = try native.data.map { try JSONSerialization.jsonObject(with:$0) as! [String:Any] }
        check("actual XPC completion encodes native result before recording usage",nativeJSON?["active"] as? Bool == true && nativeJSON?["future"] as? String == "native-only" && world.events == ["handler","resolve","used"])
        check("actual completion receives complete scoped worker telemetry",world.snapshots.allSatisfy { $0 == snapshot } && world.snapshots.count == 3)
        world.mode="good"
        let socket=await request(socket:true)
        let envelope=try socket.data.map { try JSONSerialization.jsonObject(with:$0) as! [String:Any] }
        let result=envelope?["result"] as? [String:Any]
        check("actual socket normalizes the response after recording canonical usage",result?["active"] as? Bool == true && result?["future"] == nil && world.events == ["handler","resolve","used"])
        world.mode="handler-fail"
        let operation=await request(socket:false)
        check("actual handler failure records no app use",operation.code == CUErrorCode.invalidApp.rawValue && world.events == ["handler"])
        world.mode="encode-fail"
        let encode=await request(socket:false)
        check("actual native encoding failure precedes lookup and app use",encode.data == nil && world.events == ["handler"])
        world.mode="resolve-fail"
        let resolve=await request(socket:false)
        check("actual second lookup failure overrides already encoded success",resolve.code == CUErrorCode.invalidApp.rawValue && resolve.message == "owned-post-lookup-error" && world.events == ["handler","resolve"])
        world.mode="conversion-fail"
        let conversion=await request(socket:true)
        check("native completion precedes terminal outer socket response conversion failure",conversion.serializationFailed && world.events == ["handler","resolve","used"])
        world.mode="good";Dispatch.onApplicationUsed=nil
        let absent=await request(socket:false)
        check("actual absent callback skips second target lookup",absent.data != nil && world.events == ["handler"])
        let queue=ControllerInstanceSerialExecutor()
        let carried=try await ComputerUseTelemetryContext.$current.withValue(snapshot) {
            try await queue.execute { await Task.yield();return ComputerUseTelemetryContext.snapshot() }
        }
        check("actual graph task-chain executor preserves complete caller metadata",carried == snapshot)
        check("completion and task-chain tests create no NSApplication and restore telemetry",NSApp == nil && ComputerUseTelemetryContext.snapshot().isEmpty)
        let passed=cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,"all_owned_request_results_consumed":true,"actual_socket_and_XPC_handler_completion_executed":true,"native_app_start_backend_policy_permissions_power_preparation_and_target_lookup_injected":true,"actual_default_target_resolver_read_only":true,"native_instance_manager_and_complete_action_executor_connected":false,"physical_input_capture_focus_or_preferences":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native application-use completion: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0:3
    }
    static func installWireFixture(traceURL: URL) {
        NativePreparationBindingChecks.installWireFixture(traceURL:traceURL)
        let ensure=Dispatch.ensureSystemPermissions
        Dispatch.ensureSystemPermissions={source,id in
            let result=try ensure(source,id)
            return ComputerUseTelemetryContext.snapshot().agentTurnID?.hasPrefix("usage-") == true ? .granted:result
        }
        UsageCompletionWorld(file:traceURL.appendingPathExtension("application-use")).install()
    }
}
