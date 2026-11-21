import Foundation
import Darwin

private enum Failure: Error { case decode, policy, prepare, handle, check(String) }
@MainActor private final class Trace {
    var values = [String](), next: UInt32 = 0
    func add(_ value: String) { values.append(value) }
    func activity() -> RequestActivity {
        RequestActivity(provider: .init(create: { kind, id in
            self.next += 1; id = self.next; self.add("acquire:\(kind.rawValue)"); return 0
        }, release: { self.add("release:\($0)"); return 0 }))
    }
}
@MainActor private final class Fixture {
    struct Body: Sendable { var activates = false, permissionID: String? }
    let trace = Trace()
    var decodeError = false, policyError = false, prepareError = false, handlerError = false
    var permission: ServicePermissionResult = .granted
    var body = Body(), prepareGate: CheckedContinuation<Void, Never>?, suspend = false
    var supportsPrepare = true, supportsPermission = true
    /// One of ACUA's own apps, signed by the same team as this process. Its
    /// auto-unlock grant follows the test binary's own signature: granted when
    /// the binary is team-signed, refused when it is ad-hoc signed.
    static let ownSender = SenderRequestContext(senderPID: 42, responsibleIdentity: .init(team: AcuaOwnIdentity.signingTeam(),
        signingID: AcuaOwnIdentity.bundleIdentifier + ".client", bundleID: nil, executable: nil), ancestorIdentities: [])
    var sender: SenderRequestContext? = Fixture.ownSender
    func run(_ name: String) async throws -> AuthenticatedRequestPipeline.Outcome<Int> {
        let prepare: AuthenticatedRequestPipeline.Prepare = { turn, unlock in
            self.trace.add("prepare:\(turn):\(unlock)")
            if self.suspend { await withCheckedContinuation { self.prepareGate = $0 } }
            if self.prepareError { throw Failure.prepare }
        }
        let permissions: AuthenticatedRequestPipeline.EnsurePermissions = { source, id in
            self.trace.add("permission:\(source.rawValue):\(id ?? "nil")"); return self.permission
        }
        let pipeline = AuthenticatedRequestPipeline(activity: trace.activity(), prepare: supportsPrepare ? prepare : nil, ensurePermissions: supportsPermission ? permissions : nil)
        return try await pipeline.execute(contract: .init(typeName: name), sender: sender, decode: {
            self.trace.add("decode"); if self.decodeError { throw Failure.decode }; return self.body
        }, modificationActivates: { $0.activates }, capturePermissionID: { $0.permissionID }, policy: { check in
            switch check { case .application: self.trace.add("app-policy"); case .configuration: self.trace.add("config") }
            if self.policyError { throw Failure.policy }
        }, policyRequest: { _ in self.trace.add("policy-request"); return 3 }, handle: { _ in
            self.trace.add("handle"); if self.handlerError { throw Failure.handle }; return 7
        })
    }
}
@MainActor private final class Controller: LockScreenController {
    var isLocked = true, locks = 0, unlocks = 0
    func unlock() async throws -> Bool { unlocks += 1; isLocked = false; return true }
    func lock() { locks += 1; isLocked = true }
}
@MainActor private final class Monitor: LockScreenMonitor {
    func start(onChange: @escaping @MainActor (Bool) -> Void) {}
    func stop() {}
}
@MainActor private final class Guardian: LockScreenGuardian {
    var leases = [String](), guards = 0
    func setPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) {}
    func setPendingUnlockPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) {}
    func withUnlockGuard(threadID: String, perform: @escaping @MainActor () async throws -> Bool) async throws -> Bool {
        guards += 1; return try await perform()
    }
    func retainAutoUnlockedLease(threadID: String) { leases.append("retain:\(threadID)") }
    func releaseAutoUnlockedLease(threadID: String) { leases.append("release:\(threadID)") }
}
@MainActor private final class Presenter: ServiceSystemPermissionPresenter {
    let configuration: ServiceSystemPermissions.PresenterConfiguration
    var result = ServicePermissionPresentationResult.pending
    var calls = [(Set<ServicePermissionRequirement>, ServicePermissionSource, Bool)]()
    var onPresent: (() -> Void)?
    init(_ configuration: ServiceSystemPermissions.PresenterConfiguration) { self.configuration = configuration }
    func present(requirements: Set<ServicePermissionRequirement>, source: ServicePermissionSource,
                 treatDismissalAsAbandonment: Bool) async -> ServicePermissionPresentationResult {
        calls.append((requirements, source, treatDismissalAsAbandonment)); onPresent?(); return result
    }
}
@MainActor private final class PermissionFixture {
    var presenters = [Presenter]()
    var nextResult = ServicePermissionPresentationResult.pending
    func make(_ state: ServiceSystemPermissions.State = .init()) -> ServiceSystemPermissions {
        .init(state: state, environment: .init(makePresenter: { configuration in
                let value = Presenter(configuration); value.result = self.nextResult; self.presenters.append(value); return value
            }))
    }
}
@main enum RequestCoordinationTests {
    nonisolated static func ordinaryHandler(_ body: Int) async throws -> Bool {
        await Task.yield(); return pthread_main_np() == 0
    }
    @MainActor static var results = [[String: Any]]()
    @MainActor static func check(_ condition: Bool, _ name: String) throws {
        results.append(["name": name, "passed": condition]); guard condition else { throw Failure.check(name) }
        print("PASS service request coordination \(name)")
    }
    @MainActor static func main() async throws {
        let stage = URL(fileURLWithPath: CommandLine.arguments[1])
        let requestTraits = try JSONSerialization.jsonObject(with: Data(contentsOf: stage.appendingPathComponent("request-traits-C48.json"))) as! [[String: Any]]
        for row in requestTraits {
            let type = row["requestType"] as! String, contract = ServiceRequestContract(typeName: row["requestType"] as! String)
            try check(contract.preparation.isAppUsage == row["appUsage"] as! Bool &&
                (!contract.preparation.holdsActivity && !contract.preparation.isPolicy) == row["exempt"] as! Bool &&
                contract.requiresSystemPermissions == row["requiresSystemPermissions"] as! Bool,
                "request trait conformance \(type)")
        }
        let permissionExpected = try JSONSerialization.jsonObject(with: Data(contentsOf: stage.appendingPathComponent("reference/expected.json"))) as! [String: Any]
        let permissionRows = permissionExpected["cases"] as! [[String: Any]]
        for (index, row) in permissionRows.enumerated() {
            let presentation = ServicePermissionPresentationResult(rawValue: (row["presentation"] as! NSNumber).uint8Value)!
            let source = ServicePermissionSource(rawValue: (row["source"] as! NSNumber).uint8Value)!
            let cache = row["cache"] as! [String: NSNumber]
            var fallback = false
            let result = ServicePermissionResult.resolve(presentation: presentation, source: source,
                appshotRequestID: row["id"] as? String, cached: { cache[$0].flatMap { .init(rawValue: $0.uint8Value) } },
                currentGrantState: { fallback = true; return .both })
            let tag: UInt8
            switch result {
            case .granted: tag = 4
            case .denied: tag = 5
            case .pending: tag = 6
            case .appshotPermissionsAbandoned(let state): tag = state.rawValue
            }
            try check(tag == (row["resultTag"] as! NSNumber).uint8Value && !fallback,
                "permission result mapper vector \(index)")
        }
        let unlock = Fixture.ownSender.allowsLockScreenAutoUnlock
        let prefix = "ComputerUseIPC", acquire = ["acquire:remoteUserActivity", "acquire:displaySleepPrevention"], release = ["release:2", "release:1"]
        do {
            let f = Fixture(); _ = try await f.run(prefix + "AppStartRequest")
            try check(f.trace.values == ["decode", "app-policy"] + acquire + ["prepare:true:\(unlock)", "permission:0:nil", "handle"] + release,
                "app usage decodes and checks policy before activity then prepares permissions handles and releases")
        }
        do {
            let f = Fixture(); _ = try await f.run(prefix + "AppPolicyRequest")
            try check(f.trace.values == ["decode", "policy-request"], "policy request bypasses preparation activity and permissions")
        }
        for type in ["AppStartRequest", "AppModifyRequest", "AppPolicyRequest"] {
            let f = Fixture(); f.decodeError = true
            do { _ = try await f.run(prefix + type); throw Failure.check("decode failure") }
            catch Failure.decode { try check(f.trace.values == ["decode"], "malformed early body precedes every side effect \(type)") }
        }
        for (activate, expected) in [(false, ["decode"] + acquire + ["prepare:false:\(unlock)", "permission:0:nil", "handle"] + release),
                                     (true, ["decode", "app-policy"] + acquire + ["prepare:false:\(unlock)", "permission:0:nil", "handle"] + release)] {
            let f = Fixture(); f.body.activates = activate; _ = try await f.run(prefix + "AppModifyRequest")
            try check(f.trace.values == expected, "modify activation policy branch \(activate)")
        }
        for type in ["ListAppsRequest", "StartAudioRecordingRequest"] {
            let f = Fixture(); f.policyError = true; f.decodeError = true
            do { _ = try await f.run(prefix + type); throw Failure.check("policy failure") }
            catch Failure.policy { try check(f.trace.values == ["config"], "configuration failure precedes activity and malformed late body \(type)") }
        }
        do {
            let f = Fixture(); f.policyError = true
            do { _ = try await f.run(prefix + "AppGetAppSnapshotRequest"); throw Failure.check("app policy failure") }
            catch Failure.policy { try check(f.trace.values == ["decode", "app-policy"], "denied app policy acquires no activity or unlock") }
        }
        for type in ["FrontmostWindowRequest", "StopAudioRecordingRequest", "EventStreamStatusRequest"] {
            let f = Fixture(); _ = try await f.run(prefix + type)
            let turn = type == "StopAudioRecordingRequest"
            try check(f.trace.values == acquire + ["prepare:\(turn):\(unlock)", "decode", "handle"] + release, "generic late body and false-turn preparation \(type)")
        }
        do {
            let f = Fixture(); _ = try await f.run(prefix + "TurnEndedRequest")
            try check(f.trace.values == ["decode", "handle"], "turn-ended request skips callback and activity")
        }
        for type in ["TimelineStartRequest", "TimelineResumeRequest"] {
            let f = Fixture(); _ = try await f.run(prefix + type)
            try check(f.trace.values == ["prepare:false:false", "permission:2:nil", "decode", "handle"], "unlock-exempt request still receives system permission hook \(type)")
        }
        do {
            let f = Fixture(); f.sender = nil; _ = try await f.run(prefix + "AppStartRequest")
            try check(f.trace.values.contains("prepare:true:false"), "missing sender capability cannot request automatic unlock")
        }
        do {
            let f = Fixture()
            f.sender = .init(senderPID: 42, responsibleIdentity: .init(team: "TESTTEAM01", signingID: AcuaOwnIdentity.bundleIdentifier + ".client",
                bundleID: nil, executable: nil), ancestorIdentities: [])
            _ = try await f.run(prefix + "AppStartRequest")
            try check(f.trace.values.contains("prepare:true:false"), "own bundle identifier signed by another team cannot request automatic unlock")
        }
        for (permission, code, text) in [(ServicePermissionResult.pending, CUErrorCode.permissionsPending, "Computer Use permissions are still pending"),
                                         (.denied, .permissionsNotGranted, "Computer Use permissions are not granted")] {
            let f = Fixture(); f.permission = permission; f.decodeError = true
            do { _ = try await f.run(prefix + "EventStreamStartRequest"); throw Failure.check("permission failure") }
            catch let error as ServiceError {
                try check(error.code == code && error.message == text && f.trace.values == acquire + ["prepare:false:\(unlock)", "permission:0:nil"] + release,
                    "permission failure wins over generic decode failure and releases assertions \(code.rawValue)")
            }
        }
        for state in ServicePermissionGrantState.allCases {
            let f = Fixture(); f.permission = .appshotPermissionsAbandoned(state); f.body.permissionID = "permission-id"
            let result = try await f.run(prefix + "AppStartCaptureRequest")
            guard case .appshotPermissionsAbandoned(let actual) = result else { throw Failure.check("abandonment") }
            try check(actual == state && f.trace.values == acquire + ["prepare:false:\(unlock)", "decode", "permission:1:permission-id"] + release,
                "capture abandonment returns grant state without handler \(state.rawValue)")
        }
        do {
            let f = Fixture(); f.decodeError = true
            do { _ = try await f.run(prefix + "AppStartCaptureRequest"); throw Failure.check("capture decode") }
            catch Failure.decode { try check(f.trace.values == acquire + ["prepare:false:\(unlock)", "decode"] + release, "capture-start malformed body fails after preparation before permission") }
        }
        do {
            let f = Fixture(); _ = try await f.run(prefix + "AppNextCaptureUpdateRequest")
            try check(f.trace.values == acquire + ["prepare:false:\(unlock)", "permission:1:nil", "decode", "handle"] + release,
                "next capture does not reuse capture-start permission ID")
        }
        for failing in ["prepare", "handle"] {
            let f = Fixture(); f.prepareError = failing == "prepare"; f.handlerError = failing == "handle"
            do { _ = try await f.run(prefix + "AppStartRequest"); throw Failure.check("provider failure") }
            catch Failure.prepare { try check(f.trace.values.suffix(2) == release && !f.trace.values.contains("handle"), "prepare error releases both assertions before returning") }
            catch Failure.handle { try check(f.trace.values.suffix(2) == release, "handler error releases both assertions before returning") }
        }
        do {
            let f = Fixture(); f.supportsPrepare = false; f.supportsPermission = false
            _ = try await f.run(prefix + "EventStreamStartRequest")
            try check(f.trace.values == acquire + ["decode", "handle"] + release, "optional absent callbacks do not invent failure or permission UI")
        }
        do {
            let f = Fixture(); f.suspend = true
            let task = Task { try await f.run(prefix + "EventStreamStartRequest") }
            for _ in 0..<100 { if f.prepareGate != nil { break }; await Task.yield() }
            task.cancel(); f.prepareGate?.resume(); f.prepareGate = nil
            _ = try await task.value
            try check(f.trace.values.contains("handle") && f.trace.values.suffix(2) == release,
                "pipeline does not insert cancellation failure when provider deliberately ignores task cancellation")
        }
        do {
            let trace = Trace(), pipeline = AuthenticatedRequestPipeline(activity: trace.activity(), prepare: nil, ensurePermissions: nil)
            let result = try await pipeline.execute(contract: .init(typeName: prefix + "FrontmostWindowRequest"), sender: nil,
                decode: { 1 }, policy: { _ in }, policyRequest: { _ in false }, handle: ordinaryHandler)
            guard case .handled(let ordinaryExecutor) = result else { throw Failure.check("handler result") }
            try check(ordinaryExecutor, "supplied nonisolated asynchronous handler retains its executor after suspension")
        }
        for preparesTurn in [false, true] { for unlock in [false, true] {
            var trace = [String]()
            let p = ServiceAuthenticatedPreparation(environment: .init(resetInactivity: { trace.append("idle") },
                turnAlreadyEnded: { trace.append("ended:\($0)"); return false },
                preparePIP: { trace.append("pip:\($0):\($1)") }, prepareUnlock: { trace.append("unlock:\($0 ?? "nil")") },
                endPIP: { _ in }, endUnlock: { _ in }))
            try await ComputerUseTelemetryContext.$current.withValue(.init(.init(sessionID: "thread", turnID: "turn"))) {
                try await p.prepare(preparesTurn: preparesTurn, allowsAutoUnlock: unlock)
            }
            try check(trace == ["idle"] + (preparesTurn ? ["ended:turn", "pip:thread:turn"] : []) + (unlock ? ["unlock:thread"] : []),
                "independent turn/unlock booleans and task metadata \(preparesTurn):\(unlock)")
        } }
        do {
            var trace = [String]()
            let p = ServiceAuthenticatedPreparation(environment: .init(resetInactivity: { trace.append("idle") }, turnAlreadyEnded: { _ in true },
                preparePIP: { _, _ in trace.append("pip") },
                prepareUnlock: { _ in trace.append("unlock") }, endPIP: { trace.append("end-pip:\($0)") }, endUnlock: { trace.append("end-unlock:\($0)") }))
            do {
                try await ComputerUseTelemetryContext.$current.withValue(.init(.init(sessionID: "", turnID: ""))) {
                    try await p.prepare(preparesTurn: true, allowsAutoUnlock: true)
                }; throw Failure.check("ended turn")
            } catch let error as ServiceError { try check(error.code == .agentTurnAlreadyEnded && trace == ["idle"], "empty present turn is checked and prevents follow PIP and unlock") }
            p.agentTurnEnded(threadID: "thread")
            try check(trace == ["idle", "end-pip:thread", "end-unlock:thread"], "turn-ended callback ends PIP before unlocking coordinator lease release")
        }
        do {
            let controller = Controller(), guardian = Guardian(), monitor = Monitor()
            let coordinator = LockScreenAutoUnlockCoordinator(isAutoUnlockEnabled: { true }, controller: controller, monitor: monitor, guardian: guardian)
            let p = ServiceAuthenticatedPreparation(environment: .lockScreen(coordinator: coordinator, resetInactivity: {}, turnAlreadyEnded: { _ in false },
                preparePIP: { _, _ in }, endPIP: { _ in }))
            try await ComputerUseTelemetryContext.$current.withValue(.init(.init(sessionID: "thread", turnID: "turn"))) {
                try await p.prepare(preparesTurn: true, allowsAutoUnlock: true)
                try await p.prepare(preparesTurn: false, allowsAutoUnlock: true)
            }
            try check(controller.unlocks == 1 && guardian.guards == 1 && coordinator.hasActiveAutoUnlock,
                "preparation composes actual C53 coordinator and reuses unlocked episode across requests")
            p.agentTurnEnded(threadID: "thread")
            try check(guardian.leases == ["release:thread"] && !coordinator.hasActiveAutoUnlock,
                "lease ends on turn completion rather than individual request completion")
        }
        try await permissions()
        let record: [String: Any] = ["passed": true, "cases": results.count, "results": results,
            "reusedC48RequestTraitPairs": requestTraits.count,
            "expectedPermissionResultPairs": permissionRows.count,
            "nativeUIInputCapturePowerLockOrInstalledServiceUsed": false, "productionServiceModified": false]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: stage.appendingPathComponent("component-result.json"))
    }
    @MainActor static func permissions() async throws {
        for state in ServicePermissionGrantState.allCases {
            var reads = 0
            let result = ServicePermissionResult.resolve(presentation: .denied, source: .appshot, appshotRequestID: "missing",
                cached: { _ in nil }, currentGrantState: { reads += 1; return state })
            try check(result == .appshotPermissionsAbandoned(state) && reads == 1,
                "missing abandonment cache falls through to current two-permission grant state \(state.rawValue)")
        }
        for accessibility in [false, true] { for screenRecording in [false, true] {
            for source in [ServicePermissionSource.computerUse, .appshot, .timeline] {
                let f = PermissionFixture(), coordinator = f.make(.init(accessibility: accessibility, screenRecording: screenRecording))
                let result = await coordinator.ensure(source: source, appshotRequestID: nil)
                let granted = accessibility && (source == .timeline || screenRecording)
                try check(result == (granted ? .granted : .pending) && f.presenters.count == (granted ? 0 : 1),
                    "cached permission readiness source \(source.rawValue) AX \(accessibility) screen \(screenRecording)")
                if !granted {
                    let expected: Set<ServicePermissionRequirement> = source == .timeline ? [.accessibility] : [.accessibility, .screenRecording]
                    try check(f.presenters[0].calls[0].0 == expected && !f.presenters[0].calls[0].2,
                        "permission presenter receives the required set and nil-ID dismissal policy \(source.rawValue):\(accessibility):\(screenRecording)")
                }
            }
        } }
        do {
            let f = PermissionFixture()
            let p = f.make()
            _ = await p.ensure(source: .computerUse, appshotRequestID: nil)
            _ = await p.ensure(source: .computerUse, appshotRequestID: nil)
            try check(f.presenters.count == 1 && f.presenters[0].calls.count == 2,
                "later computer-use prompts reuse the first presenter")
            _ = await p.ensure(source: .appshot, appshotRequestID: "")
            try check(f.presenters.count == 1 && f.presenters[0].calls.last!.2 && p.appshotRequestIDs == [""],
                "shared presenter handles empty present appshot ID without a new catalog")
        }
        for state in ServicePermissionGrantState.allCases where state != .both {
            let f = PermissionFixture(), p = f.make(.init(accessibility: state == .accessibility, screenRecording: state == .screenRecording))
            _ = await p.ensure(source: .appshot, appshotRequestID: "first")
            _ = await p.ensure(source: .appshot, appshotRequestID: "second")
            let old = f.presenters[0]; old.configuration.onClose()
            try check(p.abandoned == ["first": state, "second": state] && p.appshotRequestIDs.isEmpty && !p.hasPresenter,
                "close snapshots grant state for every active capture ID \(state.rawValue)")
            p.updatePermission(.accessibility, outcome: .granted); p.updatePermission(.screenRecording, outcome: .granted)
            let cached = await p.ensure(source: .appshot, appshotRequestID: "first")
            let fresh = await p.ensure(source: .appshot, appshotRequestID: "new")
            try check(cached == .appshotPermissionsAbandoned(state) && fresh == .granted && f.presenters.count == 1,
                "abandonment remains ID-specific and precedes later granted state \(state.rawValue)")
        }
        do {
            let f = PermissionFixture(), p = f.make()
            _ = await p.ensure(source: .appshot, appshotRequestID: "id")
            let presenter = f.presenters[0]
            presenter.configuration.onRequestFinished(.accessibility, .granted)
            presenter.configuration.onRequestFinished(.screenRecording, .granted)
            presenter.configuration.onClose()
            try check(p.abandoned.isEmpty && p.appshotRequestIDs.isEmpty && !p.hasPresenter,
                "fully granted close clears active IDs and presenter without adding abandonment")
            p.updatePermission(.accessibility, outcome: .cancelled); p.updatePermission(.screenRecording, outcome: .failed)
            try check(p.state.accessibility && p.state.screenRecording, "cancelled and failed permission outcomes preserve cached grants")
            p.updatePermission(.accessibility, outcome: .denied)
            try check(!p.state.accessibility && p.state.screenRecording, "denied finished request updates only its permission")
        }
        for source in [ServicePermissionSource.computerUse, .appshot, .timeline] {
            let f = PermissionFixture(); f.nextResult = .denied
            let p = f.make(.init(accessibility: false, screenRecording: true))
            let result = await p.ensure(source: source, appshotRequestID: "id")
            try check(result == (source == .appshot ? .appshotPermissionsAbandoned(.screenRecording) : .denied),
                "presenter denied result maps by source and present ID \(source.rawValue)")
            if source == .appshot {
                let withoutID = await p.ensure(source: source, appshotRequestID: nil)
                try check(withoutID == .denied, "appshot denial without ID is ordinary denied result")
            }
        }
        do {
            let f = PermissionFixture(), p = f.make()
            _ = await p.ensure(source: .appshot, appshotRequestID: "old")
            let old = f.presenters[0]; old.configuration.onClose()
            _ = await p.ensure(source: .appshot, appshotRequestID: "new")
            old.configuration.onClose()
            try check(!p.hasPresenter && p.abandoned["new"] == ServicePermissionGrantState.none,
                "late old close callback is not filtered by identity")
        }
    }
}
