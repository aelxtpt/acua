import AppKit
import ApplicationServices
import Foundation
import os

private enum DeferredNativeFailure: Error { case observer }
private final class DeferredRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    func set(_ key: SettingsNativeAXElement, _ values: [String: ControllerNativeAXValue]) { lock.withLock { stored[key] = values } }
    func set(_ key: SettingsNativeAXElement, name: String, value: ControllerNativeAXValue) { lock.withLock { stored[key, default: [:]][name] = value } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { stored[key] ?? [:] } }
    var table: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] { lock.withLock { stored } }
}
private final class DeferredBridge: ControllerNativeSettleRichBridge, Sendable {
    let rows: DeferredRows, key: SettingsNativeAXElement
    init(_ rows: DeferredRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
    var ordinaryPID: Int32 { 74001 }; var actualPID: Int32 { 74001 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    func supported() -> Set<String> { Set(rows.values(key).keys) }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { rows.values(key).filter { attributes.contains($0.key) } }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { rows.values(key)[attribute] }
    func perform(_ action: String) throws { preconditionFailure("No AX action") }
    func actions() -> [String] { ["AXPress", "AXFixtureCustomAction"] }
    func count(_ attribute: String) -> Int? { (rows.values(key)[attribute]?.raw as? [AnyObject])?.count }
    func isSettable(_ attribute: String) -> Bool { false }
    func setBoolean(_ attribute: String, _ value: Bool) throws { preconditionFailure("No AX write") }
    func actionDescription(_ name: String) throws -> String? { "Hosted action" }
    func string(for range: NSRange) throws -> String? { nil }
}
@MainActor private final class DeferredObservation: ControllerNativeSettleObservation {
    let activity = ControllerUISettleActivity<Int>(now: 0)
    var stops = 0
    func quietAge(now: () -> Double) -> Double { activity.quietAge(now: now) }
    func stop() { stops += 1 }
}
@MainActor private final class DeferredNativeFixture {
    typealias Node = ControllerNativeElementContext.Node
    let rows = DeferredRows()
    let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(74001))
    let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(74002))
    let child = SettingsNativeAXElement(element: AXUIElementCreateApplication(74003))
    let resources: ControllerNativeResources
    var time = 0.0, cancelled = false, shapeReads = 0, monitors: [EventStreamTreeInvalidationMonitor] = []
    var transactions: [EventStreamNativeTreeTransaction] = [], observation: DeferredObservation?, names: [String] = [], trace: [String] = []
    var intervals: [Double] = [], onSleep: ((Int) -> Void)?, dirtyMonitor = false
    init() {
        let rows = rows
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 74001, windowID: 51, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No event") })
        resources = .init(context: context, lookup: { DeferredBridge(rows, $0) }, windowServer: ws, actions: .init())
        var frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        rows.set(app, ["AXRole": .init(raw: "AXApplication" as NSString), "AXFocusedWindow": .init(raw: window.element), "AXMainWindow": .init(raw: window.element), "AXWindows": .init(raw: [window.element] as NSArray)])
        rows.set(window, ["AXRole": .init(raw: "AXWindow" as NSString), "AXTitle": .init(raw: "Window" as NSString), "AXFrame": .init(raw: AXValueCreate(.cgRect, &frame)!), "AXChildren": .init(raw: [child.element] as NSArray)])
        rows.set(child, ["AXRole": .init(raw: "AXWebArea" as NSString), "AXTitle": .init(raw: "Content" as NSString), "AXLoaded": .init(raw: kCFBooleanTrue!), "AXChildren": .init(raw: [] as NSArray), "AXElementBusy": .init(raw: kCFBooleanFalse!)])
    }
    var application: Node { resources.context.context.node(app) }
    var environment: ControllerNativeUISettleEnvironment {
        .init(now: { self.time }, cancelled: { self.cancelled }, sleep: { seconds in
            self.intervals.append(seconds); self.time += seconds; self.onSleep?(self.intervals.count); await Task.yield()
        }, webShaped: { _ in self.shapeReads += 1; self.trace.append("shape"); return false }, observe: { node, names in
            precondition(node.element == self.app)
            self.names = names; let observation = DeferredObservation(); self.observation = observation; return observation
        }, monitor: { node in
            self.trace.append("monitor")
            let monitor = EventStreamTreeInvalidationMonitor(application: node.element.element, io: .init(processIdentifier: { _ in throw DeferredNativeFailure.observer }, observer: { _, _ in preconditionFailure("No AX observer") }))
            monitor.withState { $0.layoutChanged = self.dirtyMonitor }; self.monitors.append(monitor); return monitor
        }, transaction: { window in
            self.trace.append("transaction")
            let values = Dictionary(uniqueKeysWithValues: self.rows.table.map { (EventStreamSnapshotAXIdentity(element: $0.key.element), $0.value.mapValues(\.raw)) })
            let transaction = EventStreamNativeTreeTransaction(root: window.element.element, snapshots: .init(attributeTable: values, requestedAttributes: Set(values.values.flatMap(\.keys))), partialValues: [:], roleFrequency: ["AXWindow": 1, "AXWebArea": 1])
            self.transactions.append(transaction); return transaction
        }, log: { _, _ in })
    }
    func settle(delay: Double = 0.3, notificationDelay: Double = 0.25, scroll: Bool = false) async throws -> ControllerNativeAppSnapshotCache? {
        let runtime = ControllerNativeClickRuntime.native(resources: resources, settleEnvironment: environment)
        return try await runtime.settle(application, delay, notificationDelay, scroll)
    }
}

private final class DeferredLease: ControllerOwnerLifetime, @unchecked Sendable { func cancel() {} }
private final class DeferredOwnerObservation: ControllerOwnerAXObservation, Sendable {
    typealias Node = ControllerNativeElementContext.Node
    func registerDestroyed(_ node: Node) throws {}
    func removeDestroyed(_ node: Node) throws {}
}
private final class DeferredOrdering: ControllerOwnerOrdering, @unchecked Sendable {
    var observedWindowIDs: [UInt32] = []
    func start() { preconditionFailure("No ordering task") }
    func stop() {}
    func menuDidOpen() { preconditionFailure("No menu effect") }
    func menuDidClose() { preconditionFailure("No menu effect") }
}
private final class DeferredError: Error, @unchecked Sendable {}

@MainActor enum NativeDeferredAppSnapshotBindingChecks {
    private static func owner(_ fixture: DeferredNativeFixture) throws -> ControllerNativeAppSnapshotBackend.Owner {
        typealias Owner = ControllerNativeAppSnapshotBackend.Owner
        let app = fixture.application, ordering = DeferredOrdering()
        let environment = Owner.Environment(resolveIdentity: { _ in (.init(application: .current), getpid()) },
            makeApplicationNode: { _ in app }, makeOrdering: { _ in ordering },
            makeSignposter: { OSSignposter(subsystem: "local.cua.fixture", category: "deferred") },
            primaryWindow: { _ in nil }, children: { _ in [] }, role: { _ in "AXApplication" },
            windowID: { _ in 51 }, menuWindowID: { _ in 51 }, actualPID: { _ in 74001 }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { _ in preconditionFailure("No attention") }, observeTermination: { _ in DeferredLease() },
            terminatedPID: { _ in nil }, observeAX: { _, _, _ in DeferredOwnerObservation() }, registerWeakOwner: { _ in },
            notificationCenter: NotificationCenter(), analytics: { _ in preconditionFailure("No analytics") },
            acquireAccessibility: { _ in preconditionFailure("No AX enablement") }, releaseAccessibility: { _ in preconditionFailure("No AX release") },
            makeFocusEnforcer: { _ in preconditionFailure("No focus") }, deactivateFocusEnforcer: { _ in preconditionFailure("No focus") },
            setFocusEnforcerPID: { _, _ in preconditionFailure("No focus") }, clearFocusEnforcerPID: { _ in preconditionFailure("No focus") },
            scheduleOnMainActor: { _ in preconditionFailure("No cleanup task") }, orderOutCursor: { _ in preconditionFailure("No cursor") },
            now: { Date() }, sleep: { _ in preconditionFailure("No readiness sleep") })
        return try .init(target: .init(bundleIdentifier: "local.cua.deferred.fixture", url: URL(fileURLWithPath: "/private/tmp/deferred-fixture.app")),
            chatID: nil, mcpRuntime: 2, isAXTreeDiffingEnabled: true, environment: environment)
    }
    private static func result(_ f: DeferredNativeFixture) throws -> ControllerNativeAppController.AppSnapshot {
        let window = f.resources.context.context.node(f.window)
        let raw = ControllerNativeAppSnapshotContext.snapshotNode(window, context: f.resources.context)
        var transformed = EventStreamTransformedNode(element: raw); transformed.role = "AXWindow"
        let tree = EventStreamCollectedTree(roots: [EventStreamCollectedItem(node: transformed, path: [0], children: [], childrenSubset: nil)])
        let revision = try EventStreamNativeTreeRevision.Revision.root(tree, lineageID: UUID().uuidString,
            identity: { .init(element: $0.element) }, render: { _ in .init(isFocusTree: false,
                roots: [.init(identity: .init(element: raw.element), text: "Window: deferred", sourcePath: [0])]) })
        let native = EventStreamNativeWindow(id: 51, processIdentifier: 74001, frame: .init(x: 0, y: 0, width: 400, height: 300), level: 0, title: "owned", ownerName: "data")
        let app = ControllerNativeAppSnapshotContext.snapshotNode(f.application, context: f.resources.context)
        let source = ControllerNativeAppSnapshotSource(context: .init(application: app, window: raw, focusedElement: nil, nativeWindow: native), window: window)
        let selection = ControllerNativeAppSnapshotSelection(.init(applicationWindow: .init(application: app, window: raw, nativeWindow: native),
            windowRevision: revision, invalidationMonitor: nil, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: source)
        return .init(attachment: .init(text: "owned capture result", screenshot: nil, mimeType: nil, screenshotNeededForContext: false, accessibilityInspectorPayload: nil),
            imageSize: nil, axTree: .init(selection: selection, isAXTreeDiffingEnabled: true))
    }
    static func run(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let f = DeferredNativeFixture(), owner = try owner(f), expected = try result(f)
        let controller = ControllerNativeAppController(owner: owner, resources: f.resources)
        let nativeRuntime = ControllerNativeClickRuntime.native(resources: f.resources, settleEnvironment: f.environment)
        var settleCalls = 0, captureCalls = 0, seenCache: ControllerNativeAppSnapshotCache?, returnedCache: ControllerNativeAppSnapshotCache?
        var beforeSettleCleared = true, sameApp = true, sameController = true, sameCache = true, exactOptions = true
        var disableValues: [Bool] = [], skipValues: [Bool] = []
        let runtime = ControllerNativeClickRuntime(click: { _, _, _, _ in preconditionFailure("No click") }, settle: { app, delay, quiet, scroll in
            settleCalls += 1; beforeSettleCleared = beforeSettleCleared && !owner.needsUISettleBeforeAppSnapshot
            sameApp = sameApp && app.element == f.app
            exactOptions = exactOptions && delay == nil && quiet == 0.25 && !scroll
            returnedCache = try await nativeRuntime.settle(app, delay, quiet, scroll)
            return returnedCache
        })
        let environment = ControllerNativeDeferredAppSnapshotEnvironment(runtime: runtime, capture: { passed, cache, disable, skip in
            captureCalls += 1; sameController = sameController && passed === controller
            sameCache = sameCache && cache === returnedCache; seenCache = cache
            disableValues.append(disable); skipValues.append(skip)
            return expected
        })
        let plain = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: false, environment: environment)
        check("actual native deferred entry returns capture result unchanged", plain.axTree === expected.axTree && plain.attachment.text == expected.attachment.text)
        check("unmarked native owner skips settle and captures nil cache", settleCalls == 0 && captureCalls == 1 && seenCache == nil && f.observation == nil)
        owner.needsUISettleBeforeAppSnapshot = true
        let marked = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: true, environment: environment)
        check("native entry consumes actual owner flag before native settle", beforeSettleCleared && !owner.needsUISettleBeforeAppSnapshot && settleCalls == 1)
        check("native entry settles current owner application with exact defaults", sameApp && exactOptions)
        check("default native settle uses ordinary app polling interval", f.intervals.count == 3 && f.intervals.allSatisfy { $0 == 0.1 })
        check("native settle produces real typed raw tree cache", seenCache?.value.tree.preorder.map { $0.node.role } == ["AXWindow", "AXWebArea"])
        check("native capture boundary receives exact settle cache", seenCache != nil && sameCache && marked.axTree === expected.axTree)
        check("native capture receives the same complete controller", sameController && controller.owner === owner && controller.resources === f.resources)
        check("native deferred capture forwards both disableAXDiffing values", disableValues == [false, true])
        check("native deferred entry never skips screenshot implicitly", skipValues == [false, false])
        check("native deferred cache retains exact monitor and transaction", seenCache?.value.invalidationMonitor === f.monitors.last && seenCache?.value.transaction.snapshots.fallbackCache === f.transactions.last?.snapshots.fallbackCache)
        let old = returnedCache
        owner.needsUISettleBeforeAppSnapshot = true; f.onSleep = { _ in owner.needsUISettleBeforeAppSnapshot = true }
        _ = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: false, environment: environment)
        check("native owner rearmed during settle remains rearmed after capture", owner.needsUISettleBeforeAppSnapshot)
        check("later native settle creates fresh cache instead of reusing previous attempt", returnedCache !== old && returnedCache != nil)
        f.onSleep = nil
        _ = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: false, environment: environment)
        check("following native request consumes newly rearmed flag", !owner.needsUISettleBeforeAppSnapshot && settleCalls == 3)
        f.cancelled = true; owner.needsUISettleBeforeAppSnapshot = true
        let priorCaptures = captureCalls
        _ = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: true, environment: environment)
        check("native cancelled settle nil result still reaches capture", captureCalls == priorCaptures + 1 && seenCache == nil && !owner.needsUISettleBeforeAppSnapshot)
        check("native cancelled observation is released", f.observation?.stops == 1)
        f.cancelled = false
        let failure = DeferredError(); owner.needsUISettleBeforeAppSnapshot = true
        let failRuntime = ControllerNativeClickRuntime(click: runtime.click, settle: { _, _, _, _ in throw failure })
        do { _ = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: false,
                environment: .init(runtime: failRuntime, capture: environment.capture)); check("native settle failure throws", false) }
        catch { check("native settle failure propagates identity and skips capture", error as AnyObject === failure && captureCalls == priorCaptures + 1 && !owner.needsUISettleBeforeAppSnapshot) }
        owner.needsUISettleBeforeAppSnapshot = true
        do { _ = try await controller.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: false,
                environment: .init(runtime: runtime, capture: { _, _, _, _ in owner.needsUISettleBeforeAppSnapshot = true; throw failure })); check("native capture failure throws", false) }
        catch { check("native capture failure preserves newly rearmed owner flag", error as AnyObject === failure && owner.needsUISettleBeforeAppSnapshot) }
        let defaults = ControllerNativeDeferredAppSnapshotEnvironment.native(resources: f.resources)
        let bound = ControllerNativeDeferredAppSnapshotBackend(controller: controller, environment: defaults)
        check("default native composition binds existing complete controller", bound.controller === controller && bound.needsUISettleBeforeAppSnapshot)
        check("native deferred data checks leave owner inactive without input resources", !owner.isActive && owner.focusEnforcer == nil && owner.virtualCursor == nil && owner.accessibilityAssertion == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "actual_native_deferred_entry_owner_settle_and_typed_cache_adapters_executed": true,
            "clock_observation_monitor_transaction_and_capture_effect_providers_injected": true,
            "actual_AX_observer_hierarchy_query_write_input_focus_cursor_window_capture_or_preferences": false,
            "production_service_entry_executed": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native deferred appSnapshot bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
