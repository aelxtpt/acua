import AppKit
import Foundation

private final class PreparationTrace: @unchecked Sendable {
    private let lock = NSLock(); private var items = [String](); private var cancelled = false
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var values: [String] { lock.withLock { items } }
    func clear() { lock.withLock { items.removeAll() } }
    var isCancelled: Bool { get { lock.withLock { cancelled } } set { lock.withLock { cancelled = newValue } } }
}
@MainActor private final class PreparationController: LockScreenController {
    var locked = true, unlocks = 0
    var isLocked: Bool { locked }
    func unlock() async throws -> Bool { unlocks += 1; locked = false; return true }
    func lock() { locked = true }
}
@MainActor private final class PreparationMonitor: LockScreenMonitor {
    func start(onChange: @escaping @MainActor (Bool) -> Void) {}
    func stop() {}
}
@MainActor private final class PreparationGuardian: LockScreenGuardian {
    let trace: PreparationTrace
    init(_ trace: PreparationTrace) { self.trace = trace }
    func setPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) {}
    func setPendingUnlockPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) {}
    func withUnlockGuard(threadID: String, perform: @escaping @MainActor () async throws -> Bool) async throws -> Bool {
        trace.add("guard:\(threadID)"); return try await perform()
    }
    func retainAutoUnlockedLease(threadID: String) { trace.add("retain:\(threadID)") }
    func releaseAutoUnlockedLease(threadID: String) { trace.add("release:\(threadID)") }
}
private struct PreparationReply: Sendable { let code: Int?; let message: String?; let data: Data? }
@MainActor enum NativePreparationBindingChecks {
    // A trusted sender is a process signed by the service's own team with an
    // ACUA host bundle identifier; only it may auto-unlock the screen. The
    // dispatcher reads the team from this process's own code signature, so the
    // fixture uses that team (TESTTEAM01 only stands in for an unsigned build).
    static let ownTeam = AcuaOwnIdentity.signingTeam() ?? "TESTTEAM01", ownHostBundle = "com.aex.computeruse.client"
    static func run(output: URL) async throws -> Int32 {
        let oldPrepare = Dispatch.prepareAuthenticatedRequest, oldEnd = Dispatch.endAuthenticatedTurn
        let oldApp = Dispatch.checkApplicationPolicy, oldConfig = Dispatch.checkGlobalConfiguration
        let oldPermission = Dispatch.ensureSystemPermissions, oldPower = Dispatch.requestActivity
        defer { Dispatch.prepareAuthenticatedRequest = oldPrepare; Dispatch.endAuthenticatedTurn = oldEnd
            Dispatch.checkApplicationPolicy = oldApp; Dispatch.checkGlobalConfiguration = oldConfig
            Dispatch.ensureSystemPermissions = oldPermission; Dispatch.requestActivity = oldPower }
        var cases = [[String: Any]]()
        func check(_ name: String, _ value: Bool) { cases.append(["name": name,"passed": value]); if !value { print("FAIL: " + name) } }
        let trace = PreparationTrace(), flags = PreparationTrace()
        Dispatch.requestActivity = .init(provider: .init(create: { kind,id in id = kind == .remoteUserActivity ? 91 : 92; trace.add("acquire:\(id)"); return 0 }, release: { trace.add("power-release:\($0)"); return 0 }))
        Dispatch.checkApplicationPolicy = { trace.add("policy:\($0)") }; Dispatch.checkGlobalConfiguration = { trace.add("config") }
        Dispatch.ensureSystemPermissions = { _,_ in trace.add("permissions"); return .pending }
        Dispatch.prepareAuthenticatedRequest = { prepares, unlock in flags.add("\(prepares):\(unlock)"); throw ServiceError(.unknownError,"owned-preparation-stop") }
        Dispatch.endAuthenticatedTurn = { _ in }
        let trusted = SenderRequestContext(senderPID: getpid(), responsibleIdentity: .init(team: ownTeam, bundleID: ownHostBundle), ancestorIdentities: [])
        let untrusted = SenderRequestContext(senderPID: getpid(), responsibleIdentity: nil, ancestorIdentities: [])
        func request(_ type: String, _ body: String, metadata: Data? = nil, trustedSender: Bool = false, cancellation: PreparationTrace? = nil) async -> PreparationReply {
            await withCheckedContinuation { continuation in DispatchQueue.global().async {
                do {
                    let data = try Dispatch.handleXPC(peer: .init(pid: getpid(),uid: getuid(),auditToken: Data()), type: type, request: Data(body.utf8), metadata: metadata, files: [], senderContext: trustedSender ? trusted : untrusted, cancelled: { cancellation?.isCancelled ?? false })
                    continuation.resume(returning: .init(code: nil,message: nil,data: data))
                } catch let e as ServiceError { continuation.resume(returning: .init(code: e.code.rawValue,message: e.message,data: nil)) }
                catch { continuation.resume(returning: .init(code: nil,message: String(describing: error),data: nil)) }
            } }
        }
        let reference = output.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("service-request-coordination/request-traits-C48.json")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: reference)) as! [[String: Any]]
        for row in rows {
            let type = row["requestType"] as! String, usage = row["appUsage"] as! Bool, exempt = row["exempt"] as! Bool
            let bypass = type == "ComputerUseIPCAppPolicyRequest" || type == "ComputerUseIPCTurnEndedRequest"
            let prepares = usage || ["ComputerUseIPCListAppsRequest","ComputerUseIPCStartAudioRecordingRequest","ComputerUseIPCStopAudioRecordingRequest"].contains(type)
            let body: String
            if type == "ComputerUseIPCAppPolicyRequest" { body = #"{"app":"/private/tmp/owned-C114-never-installed.app"}"# }
            else if type == "ComputerUseIPCAppModifyRequest" { body = #"{"app":"owned-target","modification":{"deactivate":{}}}"# }
            else if type == "ComputerUseIPCAppPerformActionRequest" { body = #"{"app":"owned-target","action":{"type":{"_0":"never-posted"}}}"# }
            else if usage { body = #"{"app":"owned-target"}"# }
            else { body = "{" }
            for allowed in [false,true] {
                trace.clear(); flags.clear()
                let reply = await request(type,body,trustedSender: allowed)
                check("actual dispatcher preparation flags \(type) \(allowed)", bypass
                    ? flags.values.isEmpty
                    : reply.message == "owned-preparation-stop" && flags.values == ["\(prepares):\(!exempt && allowed)"] && !trace.values.contains("permissions"))
            }
        }
        let controller = PreparationController(), guardian = PreparationGuardian(trace), monitor = PreparationMonitor()
        var builds = 0
        let owner = ServiceAuthenticatedPreparationOwner(environment: .init(resetInactivity: { trace.add("idle") }, turnAlreadyEnded: { turn in
            trace.add("turn:\(turn)"); return (try? Dispatch.requireActiveAgentTurn(turn)) == nil
        }, preparePIP: { trace.add("pip:\($0):\($1)") }, endPIP: { trace.add("end-pip:\($0)") }, makeCoordinator: {
            builds += 1; trace.add("coordinator"); return .init(isAutoUnlockEnabled: { true }, controller: controller, monitor: monitor, guardian: guardian)
        }))
        let snapshots = PreparationTrace()
        Dispatch.prepareAuthenticatedRequest = { prepares, unlock in
            try ServiceAuthenticatedRequestBridge(environment: .init(isMainThread: { Thread.isMainThread }, wait: { try RequestRuntime.wait(for: $0, maximumSeconds: 120) }, prepare: { prepares, unlock in
                snapshots.add("\(ComputerUseTelemetryContext.snapshot().agentSessionID ?? "nil"):\(prepares):\(unlock)")
                try await owner.prepare(preparesTurn: prepares, allowsAutoUnlock: unlock)
            })).prepare(preparesTurn: prepares, allowsAutoUnlock: unlock)
        }
        Dispatch.endAuthenticatedTurn = owner.agentTurnEnded
        let metadata = Data(#"{"session_id":"owned-C114-A","turn_id":"owned-C114-live","model":"owned","reasoning_effort":"high","turn_started_at_unix_ms":5,"user_input_requested_during_turn":false}"#.utf8)
        trace.clear()
        let live = await request("ComputerUseIPCAppStartRequest",#"{"app":"owned-target"}"#,metadata: metadata,trustedSender: true)
        check("actual worker actor preparation precedes permissions within the request activity lifetime", live.code == CUErrorCode.permissionsPending.rawValue && trace.values == ["policy:owned-target","acquire:91","acquire:92","idle","turn:owned-C114-live","follow:owned-C114-A","pip:owned-C114-A:owned-C114-live","coordinator","guard:owned-C114-A","permissions","power-release:92","power-release:91"])
        check("actual request return retains its owned auto-unlocked lease", controller.unlocks == 1 && builds == 1 && !trace.values.contains("release:owned-C114-A"))
        _ = await request("ComputerUseIPCAppStartRequest",#"{"app":"owned-target"}"#,metadata: metadata,trustedSender: true)
        check("native repeated request reuses coordinator and does not unlock again", controller.unlocks == 1 && builds == 1 && snapshots.values == ["owned-C114-A:true:true","owned-C114-A:true:true"])
        let apps = ["owned.C114.shared","owned.C114.onlyA"]
        defer { for bundle in apps { AppSessions.shared.clearStoppedByUser(bundle) } }
        for bundle in apps { _ = AppSessions.shared.stop(bundle) }
        ComputerUseTelemetryContext.$current.withValue(.init(.init(sessionID: "owned-C114-A"))) { for bundle in apps { Dispatch.applicationUsed(bundle) } }
        ComputerUseTelemetryContext.$current.withValue(.init(.init(sessionID: "owned-C114-B"))) { Dispatch.applicationUsed(apps[0]) }
        trace.clear()
        let ended = await request("ComputerUseIPCTurnEndedRequest",#"{"threadID":"owned-C114-A","turnID":"owned-C114-ended"}"#)
        for _ in 0..<50 where !trace.values.contains("release:owned-C114-A") { try await Task.sleep(for: .milliseconds(5)) }
        check("actual turn-ended request releases same owned coordinator after PIP end", ended.data != nil && trace.values == ["end-pip:owned-C114-A","release:owned-C114-A"])
        check("actual turn-end clears only unshared application stop state", (try? AppSessions.shared.validateStart(apps[1])) != nil && (try? AppSessions.shared.validateStart(apps[0])) == nil)
        _ = await request("ComputerUseIPCTurnEndedRequest",#"{"threadID":"owned-C114-B"}"#)
        check("actual last thread end clears shared stop state without a turn ID", (try? AppSessions.shared.validateStart(apps[0])) != nil)
        trace.clear()
        let stopped = await request("ComputerUseIPCAppGetAppSnapshotRequest",#"{"app":"owned-target"}"#, metadata: Data(#"{"session_id":"owned-C114-A","turn_id":"owned-C114-ended"}"#.utf8), trustedSender: true)
        check("actual ended-turn preparation prevents PIP unlock and permissions", stopped.code == CUErrorCode.agentTurnAlreadyEnded.rawValue && trace.values.contains("idle") && !trace.values.contains("permissions") && !trace.values.contains(where: { $0.hasPrefix("pip:") }))
        let cancellation = PreparationTrace(), late = PreparationTrace()
        Dispatch.prepareAuthenticatedRequest = { prepares, unlock in
            try ServiceAuthenticatedRequestBridge(environment: .init(isMainThread: { Thread.isMainThread }, wait: { try RequestRuntime.wait(for: $0, maximumSeconds: 120) }, prepare: { _,_ in
                late.add("entered")
                do { try await Task.sleep(for: .seconds(2)) } catch { late.add(Task.isCancelled ? "cancelled" : "error"); throw error }
            })).prepare(preparesTurn: prepares, allowsAutoUnlock: unlock)
        }
        trace.clear()
        let canceller = Task { @MainActor in
            for _ in 0..<100 where !late.values.contains("entered") { try await Task.sleep(for: .milliseconds(5)) }
            cancellation.isCancelled = true
        }
        let cancelled = await request("ComputerUseIPCAppStartRequest",#"{"app":"owned-target"}"#, cancellation: cancellation)
        try await canceller.value
        for _ in 0..<100 where !late.values.contains("cancelled") { try await Task.sleep(for: .milliseconds(5)) }
        check("actual native request cancellation interrupts preparation and its actor task", cancelled.code == CUErrorCode.unknownError.rawValue && cancelled.message == "Request cancelled" && late.values == ["entered","cancelled"] && !trace.values.contains("permissions"))
        check("cancelled native preparation still releases both owned power assertions", Array(trace.values.suffix(2)) == ["power-release:92","power-release:91"])
        let directory = URL(fileURLWithPath: "/private/tmp/owned-C114-login-\(UUID().uuidString.prefix(8))",isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = ServiceLockScreenNativeOwner(socketPath: directory.appendingPathComponent("login.sock").path)
        check("real native assembly reuses the same lazy coordinator", native.coordinator === native.coordinator)
        native.start()
        check("real native owner starts only its owned login authorization socket", native.loginSocket.isOpen && FileManager.default.fileExists(atPath: native.loginSocket.socketPath))
        native.stop()
        check("real native owner closes and unlinks owned socket", !native.loginSocket.isOpen && !FileManager.default.fileExists(atPath: native.loginSocket.socketPath))
        check("native preparation tests do not initialize NSApplication or leak telemetry", NSApp == nil && ComputerUseTelemetryContext.snapshot().isEmpty)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed":passed,"cases":cases,"all_owned_tasks_terminal":true,"request_trait_rows_reused":rows.count,"actual_native_dispatch_and_worker_actor_preparation":true,"owned_lock_PIP_permission_power_and_sender_providers":true,"real_native_default_owner_construction_and_owned_login_socket":true,"native_unlock_helper_launch_input_capture_or_real_PIP":false,"request_app_use_recording_in_native_executor_connected":false],options: [.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native authenticated preparation: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
    static func installWireFixture(traceURL: URL) {
        NativePolicyOrderingBindingChecks.installWireFixture(traceURL: traceURL)
        let preparationTrace = traceURL.appendingPathExtension("preparation")
        Dispatch.prepareAuthenticatedRequest = { prepares, unlock in
            try ServiceAuthenticatedRequestBridge(environment: .init(isMainThread: { Thread.isMainThread }, wait: { try RequestRuntime.wait(for: $0, maximumSeconds: 120) }, prepare: { prepares, unlock in
                let metadata = ComputerUseTelemetryContext.snapshot()
                var cancelled = false
                if metadata.agentTurnID == "cancel-prep" {
                    do { try await Task.sleep(for: .seconds(2)) } catch { cancelled = Task.isCancelled }
                }
                let record: [String:Any] = ["session":metadata.agentSessionID as Any? ?? NSNull(),"turn":metadata.agentTurnID as Any? ?? NSNull(),"prepares":prepares,"unlock":unlock,"cancelled":cancelled]
                var bytes = try! JSONSerialization.data(withJSONObject: record, options: .sortedKeys); bytes.append(10)
                if !FileManager.default.fileExists(atPath: preparationTrace.path) { _ = FileManager.default.createFile(atPath: preparationTrace.path,contents:Data()) }
                let file = try! FileHandle(forWritingTo: preparationTrace); try! file.seekToEnd(); try! file.write(contentsOf: bytes); try! file.close()
                try Task.checkCancellation()
                if prepares { try Dispatch.requireActiveAgentTurn(metadata.agentTurnID) }
            })).prepare(preparesTurn: prepares,allowsAutoUnlock: unlock)
        }
        Dispatch.endAuthenticatedTurn = { _ in }
    }
}
