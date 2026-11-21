import AppKit
import ApplicationServices
import Foundation
import os

final class LifecycleTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks = 0
    private var stored: [String] = [], jobs: [Task<Void, Never>] = []
    func tick() -> Duration { lock.withLock { ticks += 101; return .seconds(ticks) } }
    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
    func task(_ value: Task<Void, Never>) { lock.withLock { jobs.append(value) } }
    func drain() async { let current = lock.withLock { jobs }; for job in current { await job.value } }
}
final class LifecycleOrdering: ControllerOwnerOrdering, @unchecked Sendable {
    let trace: LifecycleTrace
    private let lock = NSLock(); private var ids: [UInt32] = []
    init(_ trace: LifecycleTrace) { self.trace = trace }
    var observedWindowIDs: [UInt32] { get { lock.withLock { ids } } set { lock.withLock { ids = newValue } } }
    func start() { trace.add("ordering.start") }; func stop() { trace.add("ordering.stop") }
    func menuDidOpen() { preconditionFailure("No menu") }; func menuDidClose() { preconditionFailure("No menu") }
}
@MainActor final class LifecycleFixture {
    let data = SecondaryScrollDataNativeFixture(), trace = LifecycleTrace()
    let target = ComputerUseApplicationTarget(bundleIdentifier: "local.cua.lifecycle.fixture",
        url: URL(fileURLWithPath: "/private/tmp/Native Session/Fixture %.app"))
    let bindings: ControllerNativeInstanceBindings
    var configurations: [ControllerRequestConfiguration] = [], failLaunch = false
    init(bindings supplied: ControllerNativeInstanceBindings? = nil) {
        bindings = supplied ?? .init(input: .init(ignoredSourcePID: getpid(), events: { AsyncStream { $0.finish() } },
            resolveTarget: { _ in preconditionFailure("No actual input") }))
    }
    func make(_ target: ComputerUseApplicationTarget, _ config: ControllerRequestConfiguration) throws -> ControllerNativeAppController {
        configurations.append(config); trace.add("construct")
        typealias Owner = ControllerNativeAppSnapshotBackend.Owner
        let trace = trace, app = data.application, ordering = LifecycleOrdering(trace)
        let environment = Owner.Environment(resolveIdentity: { _ in (.init(application: .current), getpid()) },
            makeApplicationNode: { _ in app }, makeOrdering: { _ in ordering },
            makeSignposter: { OSSignposter(subsystem: "local.cua.fixture", category: "lifecycle") },
            primaryWindow: { _ in nil }, children: { _ in [] }, role: { _ in "AXApplication" },
            windowID: { _ in 51 }, menuWindowID: { _ in 51 }, actualPID: { _ in getpid() }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { _ in preconditionFailure("No attention") }, observeTermination: { _ in SecondaryScrollDataLease() },
            terminatedPID: { _ in nil }, observeAX: { _, _, _ in SecondaryScrollDataOwnerObservation() }, registerWeakOwner: { _ in },
            notificationCenter: NotificationCenter(), analytics: { trace.add("analytics.\($0)") },
            acquireAccessibility: { _ in trace.add("acquire"); return nil }, releaseAccessibility: { _ in preconditionFailure("No native assertion") },
            makeFocusEnforcer: { _ in preconditionFailure("No focus") }, deactivateFocusEnforcer: { _ in preconditionFailure("No focus") },
            setFocusEnforcerPID: { _, _ in preconditionFailure("No focus") }, clearFocusEnforcerPID: { _ in preconditionFailure("No focus") },
            scheduleOnMainActor: { work in trace.task(Task { @MainActor in await work() }) },
            orderOutCursor: { _ in preconditionFailure("No cursor") }, now: { Date() }, sleep: { _ in preconditionFailure("No readiness sleep") })
        let owner = try Owner(target: target, chatID: nil, mcpRuntime: config.mcpRuntime,
            isAXTreeDiffingEnabled: config.isAXTreeDiffingEnabled, environment: environment)
        return .init(owner: owner, resources: data.resources)
    }
    var lifecycle: ControllerNativeApplicationLifecycle {
        let clockTrace = trace
        return .init(bindings: bindings, environment: .init(prepareLaunch: { _ in
            self.trace.add("launch"); if self.failLaunch { throw CocoaError(.fileReadUnknown) }
        }, makeController: make, interventionClock: .init(now: { clockTrace.tick() }, sleep: { _ in })))
    }
    func finish() async {
        for instance in bindings.manager.instances { instance.controller.deactivate() }
        bindings.stopMonitoring(); await trace.drain(); await Task.yield()
    }
}

@MainActor enum NativeLaunchStateChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let target = ComputerUseApplicationTarget(bundleIdentifier: "local.cua.launch.fixture", url: URL(fileURLWithPath: "/private/tmp/Owned Launch %.app"))
        var configuration: NSWorkspace.OpenConfiguration?, openedURL: URL?, completionApplication: NSRunningApplication?
        let opener = ControllerNativeApplicationOpener(openURL: { url, options, callback in
            openedURL = url; configuration = options
            let returned = NSRunningApplication.current; completionApplication = returned; callback(returned, nil)
        })
        let opened = try await opener.open(target)
        check("actual Workspace configuration disables activation and running substitution", configuration?.activates == false && configuration?.allowsRunningApplicationSubstitution == false)
        check("native opener preserves exact target URL and completion application", openedURL == target.url && opened.application === completionApplication)
        check("native opener preserves other platform configuration defaults", configuration?.createsNewApplicationInstance == false && configuration?.hides == false && configuration?.hidesOthers == false && configuration?.arguments == [])
        let expectedError = NSError(domain: "OwnedLaunch", code: 73, userInfo: ["owned-key": "owned-value"])
        for alsoApplication in [false, true] {
            var caught = false
            do {
                _ = try await ControllerNativeApplicationOpener(openURL: { _, _, callback in callback(alsoApplication ? .current : nil, expectedError) }).open(target)
            } catch { let actual = error as NSError
                caught = actual.domain == expectedError.domain && actual.code == expectedError.code && NSDictionary(dictionary: actual.userInfo).isEqual(to: expectedError.userInfo) }
            check("native open callback error takes precedence with app=\(alsoApplication)", caught)
        }
        do {
            let asynchronous = ControllerNativeApplicationOpener(openURL: { _, _, callback in
                DispatchQueue.global().async { callback(.current, nil) }
            })
            let app = try await asynchronous.open(target)
            check("native open continuation accepts concurrent completion without actor-owned result mutation", app.application.processIdentifier == getpid())
            let task = Task { @MainActor in
                let cancelled = Task.isCancelled
                let value = try await opener.open(target)
                return (cancelled, value.application.processIdentifier)
            }
            task.cancel(); let (cancelled, pid) = try await task.value
            check("native open does not invent a caller-cancellation guard before successful completion", cancelled && pid == getpid())
        }
        do {
            let f = SecondaryScrollDataNativeFixture()
            var opens = 0, settles = 0
            let environment = ControllerNativeLaunchEnvironment(running: { _ in .init(application: .current) },
                node: { _ in f.application }, opener: .init(openURL: { _, _, callback in opens += 1; callback(.current, nil) }),
                now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in preconditionFailure("Window already present") },
                settle: { app, delay, notification, scroll in
                    check("native launch settle passes exact shared application and settle timing", app.element == f.app && delay == 0.05 && notification == 0.25 && !scroll)
                    settles += 1; return nil
                })
            let backend = ControllerNativeLaunchBackend(resources: f.resources, environment: environment)
            try await ControllerLaunchPreparation(backend: backend).prepare(target)
            check("native existing primary with absent minimized flag does not open", opens == 0 && settles == 0)
            f.rows.set(f.window, name: "AXMinimized", value: .init(raw: kCFBooleanTrue!))
            try await ControllerLaunchPreparation(backend: backend).prepare(target)
            check("native minimized hosted window uses opener and settles returned application", opens == 1 && settles == 1)
            check("native launch target selection uses canonical window snapshots without AX action", f.rows.actions.isEmpty)
        }
        do {
            let f = LifecycleFixture()
            var sender = SenderRequestContext(senderPID: getpid(), responsibleIdentity: nil, ancestorIdentities: [])
            sender.clientMetadata = .init(clientType: .nodeRepl, mcpRuntime: .legacyMCP)
            let first = try await f.lifecycle.start(f.target, requestedIdentifier: "alias", sender: sender)
            let instance = f.bindings.manager.instance(for: f.target.identifier)!
            check("native start prepares launch before constructing canonical controller", f.trace.values.prefix(2) == ["launch", "construct"])
            check("native start activates automation and returns exact decoded identity", first.active && first.currentApp?.pid == getpid() && first.currentApp?.bundleIdentifier == f.target.bundleIdentifier && first.currentApp?.appPath == f.target.url.path(percentEncoded: false))
            check("native start retains the first sender configuration on canonical instance", instance.configuration.isAXTreeDiffingEnabled && instance.configuration.mcpRuntime == 0 && instance.controller.owner.isAXTreeDiffingEnabled && instance.controller.owner.mcpRuntime == 0)
            check("native active instance and input monitor share canonical store", f.bindings.manager.activeInstances.count == 1 && f.bindings.manager.instance(for: "alias") == nil)
            let controller = instance.controller
            let second = try await f.lifecycle.start(f.target, requestedIdentifier: "another alias", sender: nil)
            check("later start reuses controller queue and initial configuration", second.active && f.bindings.manager.instance(for: f.target.identifier) === instance && instance.controller === controller && f.configurations.count == 1 && instance.configuration.mcpRuntime == 0)
            check("repeated start does not repeat activation resource acquisition", f.trace.values.filter { $0 == "acquire" }.count == 1 && f.trace.values.filter { $0 == "ordering.start" }.count == 1)
            let deactivated = try await f.lifecycle.modify(f.target, requestedIdentifier: "alias", sender: nil, deactivate: true)
            check("native deactivate removes canonical instance and returns inactive existing identity", !deactivated.active && deactivated.currentApp?.pid == getpid() && f.bindings.manager.instance(for: f.target.identifier) == nil)
            check("deactivation does not turn into user stop or OS termination", !f.bindings.manager.wasStoppedByUser(for: f.target.identifier) && !controller.owner.runningApplication.application.isTerminated)
            check("deactivation stops ordering and clears active count", f.trace.values.filter { $0 == "ordering.stop" }.count == 1 && f.bindings.manager.activeInstances.isEmpty)
            var absent = false
            do { _ = try await f.lifecycle.modify(f.target, requestedIdentifier: "raw alias", sender: nil, deactivate: false) }
            catch ControllerInstanceResolutionError.noInstance(let name) { absent = name == "raw alias" }
            check("modify never creates a missing instance and preserves the requested error identifier", absent && f.configurations.count == 1)
            await f.finish()
        }
        do {
            let f = LifecycleFixture(), config = ControllerRequestConfiguration(sender: nil)
            let controller = try f.make(f.target, config)
            let instance = ControllerNativeInstanceBindings.Manager.Instance(target: f.target, configuration: config, controller: controller)
            f.bindings.manager.setInstance(instance)
            let activated = try await f.lifecycle.modify(f.target, requestedIdentifier: "inactive alias", sender: nil, deactivate: false)
            check("native modify activates an existing inactive controller on its same queue without launching", activated.active && instance.controller === controller && !f.trace.values.contains("launch") && f.configurations.count == 1)
            f.bindings.manager.registerUserInterruptedIntervention(for: f.target.identifier)
            var interrupted = false
            do { _ = try await f.lifecycle.modify(f.target, requestedIdentifier: "interrupted alias", sender: nil, deactivate: false) }
            catch ControllerInterventionAdmissionError.userIntervened(let message) { interrupted = message.contains("interrupted alias") && message.contains("still interacting") }
            check("native activation honors intervention admission before touching activation state", interrupted && f.trace.values.filter { $0 == "ordering.start" }.count == 1)
            let deactivated = try await f.lifecycle.modify(f.target, requestedIdentifier: "deactivate alias", sender: nil, deactivate: true)
            check("native deactivation bypasses activation admission and clears interruption without marking stop", !deactivated.active && f.bindings.manager.interventionReason(for: f.target.identifier) == nil && f.bindings.manager.instance(for: f.target.identifier) == nil)
            await f.finish()
        }
        do {
            let f = LifecycleFixture(); f.failLaunch = true; var failed = false
            do { _ = try await f.lifecycle.start(f.target, requestedIdentifier: "alias", sender: nil) } catch { failed = true }
            check("launch failure prevents native instance construction and activation", failed && f.trace.values == ["launch"] && f.bindings.manager.instances.isEmpty)
            await f.finish()
        }
        do {
            let f = LifecycleFixture(); f.bindings.manager.markStoppedByUser(for: f.target.identifier); var failed = false
            do { _ = try await f.lifecycle.start(f.target, requestedIdentifier: "stopped alias", sender: nil) }
            catch ControllerInstanceResolutionError.stoppedByUser(let name) { failed = name == "stopped alias" }
            check("start keeps launch-before-stopped-resolution ordering", failed && f.trace.values == ["launch"] && f.bindings.manager.instances.isEmpty)
            await f.finish()
        }
        for bundle in ["com.apple.Terminal", "com.apple.UserNotificationCenter", "com.apple.SecurityAgent"] {
            let f = LifecycleFixture(), forbidden = ComputerUseApplicationTarget(bundleIdentifier: bundle, url: target.url)
            var failed = false
            do { _ = try await f.lifecycle.start(forbidden, requestedIdentifier: "forbidden alias", sender: nil) }
            catch ControllerNativeApplicationLifecycleError.forbiddenTarget(let identifier) { failed = identifier == bundle }
            check("native forbidden target \(bundle) fails before launch or instance lookup", failed && f.trace.values.isEmpty && f.bindings.manager.instances.isEmpty)
            await f.finish()
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks,
            "actual_native_launch_configuration_and_canonical_lifecycle_bindings_executed": true,
            "application_open_AX_input_ordering_activation_effect_providers_intercepted": true,
            "actual_OS_launch_focus_input_cursor_window_capture_preferences_or_clipboard": false,
            "ordinary_native_request_routing_accepted": false,
            "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native launch/state bindings: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
