import Foundation

@MainActor private final class ServiceOwnedWindow: PermissionWindowHosting, PermissionWindowPresenting {
    var hasWindow = true, hasContent = true, isVisible = false
    var closed: (@MainActor @Sendable () -> Void)?
    private var continuations = [AsyncStream<Bool>.Continuation]()
    func currentWindow() -> (any PermissionWindowPresenting)? { hasWindow ? self : nil }
    func layoutAndFit() {}
    func center() {}
    func setLevel(_ level: Int) {}
    func closeWaiter() -> PermissionWindowCloseWaiter {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(); continuations.append(continuation)
        return { var iterator = stream.makeAsyncIterator(); return await iterator.next() == true }
    }
    func activateApplication() {}
    func show() { isVisible = true }
    func makeKeyAndOrderFront() {}
    func close() {
        isVisible = false
        continuations.forEach { $0.yield(true); $0.finish() }
        closed?()
    }
}
@MainActor private final class ServiceWorld {
    typealias Coordinator = PermissionWindowCoordinator<ServicePermissionRequirement>
    var statuses: [ServicePermissionRequirement: PermissionWindowStatus] = [.accessibility:.notDetermined,.screenRecording:.notDetermined]
    var coordinator: Coordinator?, window: ServiceOwnedWindow?
    var made = 0
    var sources = [PermissionWindowSource](), completions = [Coordinator.PresentationCompletion]()
    var configurations = [ServiceSystemPermissions.PresenterConfiguration]()
    func permissions() -> ServiceSystemPermissions {
        .init(environment: .init(makePresenter: { [self] configuration in
                made += 1; configurations.append(configuration)
                let window = ServiceOwnedWindow()
                let core = Coordinator(rows: [.init(requirement:.accessibility,isSupplemental:false),
                    .init(requirement:.screenRecording,isSupplemental:false)], window:window, pendingTimeout:.seconds(1),
                    environment:.init(status: { [self] in statuses[$0] ?? .unknown }, sleep: { _ in },
                        requestFinished: { requirement, outcome in
                            configuration.onRequestFinished(requirement, PermissionWindowServiceAdapter.requestOutcome(outcome))
                        }, closed:configuration.onClose,
                        presentationStarted: { [self] in sources.append($0.source) },
                        presentationFinished: { [self] in completions.append($0) }))
                window.closed = { [weak core] in core?.windowWillClose() }
                self.coordinator = core; self.window = window
                return PermissionWindowServiceAdapter(coordinator:core)
            }))
    }
}

@main enum ServicePermissionWindowTests {
    @MainActor static func main() async throws {
        var rows = [[String:Any]]()
        func check(_ value: Bool, _ name: String) { rows.append(["name":name,"passed":value]); print("\(value ? "PASS":"FAIL") service permission window \(name)") }
        func settled(_ core: ServiceWorld.Coordinator) async -> Bool {
            let deadline=ContinuousClock.now + .seconds(1)
            while core.hasRequestTask && ContinuousClock.now < deadline { await Task.yield() }
            return !core.hasRequestTask
        }
        check(PermissionWindowServiceAdapter.windowSource(.computerUse).rawValue == 2, "IPC computerUse0 maps to window computerUse2")
        check(PermissionWindowServiceAdapter.windowSource(.appshot).rawValue == 0, "IPC appshot1 maps to window appshot0")
        check(PermissionWindowServiceAdapter.windowSource(.timeline).rawValue == 5, "IPC timeline2 maps to window timeline5")
        for outcome in [PermissionWindowRequestOutcome.granted,.denied,.cancelled,.failed] {
            check(PermissionWindowServiceAdapter.requestOutcome(outcome).rawValue == outcome.rawValue, "request callback outcome mapping \(outcome.rawValue)")
        }
        let world=ServiceWorld(), permissions=world.permissions()
        check(await permissions.ensure(source:.computerUse,appshotRequestID:nil) == .pending, "actual C63 permission hook receives pending from C65 window coordinator")
        let core=world.coordinator!, window=world.window!
        check(world.made == 1 && core.state.requested == [.accessibility,.screenRecording] && window.isVisible, "shared presenter owns both requested permissions and remains visible")
        check(await permissions.ensure(source:.timeline,appshotRequestID:nil) == .pending && world.made == 1 && core.state.requested == [.accessibility], "Timeline reuses presenter with accessibility-only requirements")
        check(await permissions.ensure(source:.appshot,appshotRequestID:"owned-id") == .pending && permissions.appshotRequestIDs == ["owned-id"], "Appshot registers abandonment ID while sharing presenter")
        check(world.sources == [.computerUse,.timeline,.appshot], "three calls retain window source tags distinct from IPC tags")
        _ = core.request(.accessibility) { world.statuses[.accessibility] = .authorized; return .granted }
        check(await settled(core) && permissions.state.accessibility && !permissions.state.screenRecording, "actual callback propagates accessibility grant to C63 state")
        world.statuses[.screenRecording] = .unknown
        _ = core.request(.screenRecording) { .denied }
        check(await settled(core) && !permissions.state.screenRecording && core.state.statuses[.screenRecording] == .denied, "denied callback and unknown refresh retain displayed denial and C63 missing state")
        window.close()
        check(!permissions.hasPresenter && permissions.appshotRequestIDs.isEmpty && permissions.abandoned["owned-id"] == .accessibility, "actual close callback removes shared presenter and stores partial Appshot grant")
        check(await permissions.ensure(source:.appshot,appshotRequestID:"owned-id") == .appshotPermissionsAbandoned(.accessibility) && world.made == 1, "abandoned request returns stored partial grant without recreating window")
        permissions.updatePermission(.screenRecording,outcome:.granted)
        check(await permissions.ensure(source:.appshot,appshotRequestID:"owned-id") == .appshotPermissionsAbandoned(.accessibility), "later grant does not erase a previous request's abandonment snapshot")
        check(await permissions.ensure(source:.appshot,appshotRequestID:"fresh-id") == .granted && world.made == 1, "fresh request with both cached grants bypasses presentation")
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let record:[String:Any]=["passed":passed,"cases":rows.count,"results":rows,
            "actualC63AndC65ComponentsComposed":true,"nativePermissionWindowSettingsInputOrCapture":false]
        try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if !passed { exit(1) }
    }
}
