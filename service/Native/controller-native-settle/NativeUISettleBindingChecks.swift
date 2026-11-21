import AppKit
import ApplicationServices
import Foundation

private enum NativeSettleTestFailure: Error { case observer }
private final class SettleRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    func set(_ key: SettingsNativeAXElement, _ values: [String: ControllerNativeAXValue]) { lock.withLock { stored[key] = values } }
    func set(_ key: SettingsNativeAXElement, name: String, value: ControllerNativeAXValue) { lock.withLock { stored[key, default: [:]][name] = value } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { stored[key] ?? [:] } }
    var table: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] { lock.withLock { stored } }
}
private final class SettleBridge: ControllerNativeSettleRichBridge, Sendable {
    let rows: SettleRows, key: SettingsNativeAXElement
    init(_ rows: SettleRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
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
@MainActor private final class OwnedSettleObservation: ControllerNativeSettleObservation {
    let activity = ControllerUISettleActivity<Int>(now: 0)
    var stops = 0
    func quietAge(now: () -> Double) -> Double { activity.quietAge(now: now) }
    func stop() { stops += 1 }
}
@MainActor private final class NativeSettleFixture {
    typealias Node = ControllerNativeElementContext.Node
    let rows = SettleRows()
    let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(74001))
    let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(74002))
    let child = SettingsNativeAXElement(element: AXUIElementCreateApplication(74003))
    let resources: ControllerNativeResources
    var time = 0.0, cancelled = false, shapeReads = 0, monitors: [EventStreamTreeInvalidationMonitor] = []
    var transactions: [EventStreamNativeTreeTransaction] = [], observation: OwnedSettleObservation?, names: [String] = [], trace: [String] = []
    var intervals: [Double] = [], onSleep: ((Int) -> Void)?, dirtyMonitor = false
    init() {
        let rows = rows
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 74001, windowID: 51, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No event") })
        resources = .init(context: context, lookup: { SettleBridge(rows, $0) }, windowServer: ws, actions: .init())
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
            self.names = names; let observation = OwnedSettleObservation(); self.observation = observation; return observation
        }, monitor: { node in
            self.trace.append("monitor")
            let monitor = EventStreamTreeInvalidationMonitor(application: node.element.element, io: .init(processIdentifier: { _ in throw NativeSettleTestFailure.observer }, observer: { _, _ in preconditionFailure("No AX observer") }))
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
@MainActor private final class CacheConsumer: EventStreamSelectionExtractorBackend {
    typealias Element = EventStreamAXNode; typealias Identity = EventStreamSnapshotAXIdentity
    typealias Transaction = EventStreamNativeTreeTransaction; typealias Monitor = EventStreamTreeInvalidationMonitor
    typealias Assertion = NSObject; typealias Revision = Int
    let expected: EventStreamNativeCaptureTreeCache
    var treeIdentity = false, transactionIdentity = false, captures = 0
    init(_ cache: EventStreamNativeCaptureTreeCache) { expected = cache }
    func identity(_ element: Element) -> Identity { .init(element: element.element) }
    func enableAccessibility(application: Element, window: Element, type: EventStreamElementContextType) -> Assertion? { preconditionFailure("No AX enablement") }
    func disable(_ assertion: Assertion) { preconditionFailure("No AX disable") }
    func focusedElement(of application: Element) -> Element? { nil }
    func makeMonitor(application: Element) -> Monitor { preconditionFailure("Cache monitor must be reused") }
    func isWebShaped(_ application: Element) -> Bool { false }
    func subtreeTransaction(root: Element, maximumChildCount: Int) -> Transaction { preconditionFailure("Cache transaction must be reused") }
    func makeContext(type: EventStreamElementContextType, application: Element, window: Element) -> EventStreamMacTransformationContext {
        .init(type: type, urlShortener: .init(configuration: .init(individualLimit: nil, totalLimit: nil, includeQuery: true, includeFragment: true)))
    }
    func perform<Result>(_ transaction: Transaction, work: () throws -> Result) rethrows -> Result {
        transactionIdentity = transaction.snapshots.fallbackCache === expected.transaction.snapshots.fallbackCache
        return try EventStreamTreeTransactions.$current.withValue(transaction, operation: work)
    }
    func capture(root: Element, window: Element, application: Element, focusedElement: Element?, cachedTree: EventStreamCollectedTree<Element>?, previous: Int?, context: inout EventStreamMacTransformationContext, alwaysIncludeScreenshot: Bool, enableAXDiffing: Bool) throws -> EventStreamSelectionCaptureOutput<Int> {
        captures += 1
        treeIdentity = cachedTree?.roots.first?.node.element === expected.tree.roots.first?.node.element
        precondition(EventStreamTreeTransactions.current?.snapshots.fallbackCache === expected.transaction.snapshots.fallbackCache)
        return .init(revision: 42, webAreaURL: nil, contextType: .fullUIContext, screenshotNeededForContext: false)
    }
}
@MainActor enum NativeUISettleBindingChecks {
    /// Deliberately keep main occupied until the observer callback owns the
    /// activity lock. Yielding main during setup could complete its title read
    /// before quiet sampling, hiding the lock inversion this case must detect.
    /// Only this synchronous setup blocks, bounded to one second; the tested
    /// quiet sampler below must release main by awaiting its worker task.
    private static func startCoupledCallback(_ activity: ControllerUISettleActivity<SettingsNativeAXElement>,
        key: SettingsNativeAXElement, reader: ControllerNativeSettleTitleReader) throws -> Task<Bool, Never> {
        let started = DispatchSemaphore(value: 0)
        let callback = Task.detached {
            activity.receive("AXTitleChanged", key: key, title: { started.signal(); return reader.title(key) }, now: CFAbsoluteTimeGetCurrent)
        }
        guard started.wait(timeout: .now() + 1) == .success else { throw NativeSettleTestFailure.observer }
        return callback
    }
    static func run(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); FileHandle.standardOutput.write(Data("SETTLE \(cases.count): \(name): \(value)\n".utf8)) }
        let f = NativeSettleFixture(); let cache = try await f.settle(scroll: true)!
        check("native runtime now composes click and a concrete settle capability", cache.value.tree.roots.count == 1)
        check("native settle forwards ordered scroll-inclusive notifications", f.names == ControllerUISettle<ControllerNativeUISettle>.notifications + ["AXValueChanged"])
        check("native settle sleeps supplied interval and releases observation once", f.intervals == [0.3] && f.observation?.stops == 1)
        check("native settle monitor precedes transaction and two shape samples", f.trace == ["monitor", "transaction", "shape", "shape"] && f.shapeReads == 2)
        check("native raw collection preserves complete window and child fields", cache.value.tree.preorder.map { $0.node.role } == ["AXWindow", "AXWebArea"] && cache.value.tree.preorder.map { $0.node.title } == ["Window", "Content"])
        check("native collection preserves predefined actions and reads custom hosted descriptions", cache.value.tree.preorder.allSatisfy {
            $0.node.actionDescriptions.map(\.name) == ["AXPress", "AXFixtureCustomAction"] &&
            $0.node.actionDescriptions.map(\.description) == ["Press", "Hosted action"]
        })
        check("cache retains exact monitor identity even with no live observer", cache.value.invalidationMonitor === f.monitors[0] && !cache.value.invalidationMonitor.hasObserver)
        check("cache retains exact native transaction and fallback cache", CFEqual(cache.value.transaction.root, f.window.element) && cache.value.transaction.snapshots.fallbackCache === f.transactions[0].snapshots.fallbackCache)
        check("native collection root and child use correct AX identities", cache.value.tree.roots.first?.node.element.element == f.window.element && cache.value.tree.preorder.last?.node.element.element == f.child.element)
        check("native settle returns without leaving a transaction in TaskLocal", EventStreamTreeTransactions.current == nil)
        let consumer = CacheConsumer(cache.value)
        let result = try EventStreamSelectionExtractor.extract(application: ControllerNativeAppSnapshotContext.snapshotNode(f.application, context: f.resources.context),
            window: cache.value.tree.roots[0].node.element, focusedElement: nil, type: .fullUIContext, cache: cache.value,
            performAccessibilityEnablement: false, backend: consumer)
        check("next selection extraction accepts settle tree cache without recapture", result.capture.revision == 42 && consumer.captures == 1 && consumer.treeIdentity)
        check("next extraction reuses cache transaction under the outer TaskLocal", consumer.transactionIdentity && EventStreamTreeTransactions.current == nil)
        check("next extraction retains settle invalidation monitor", result.invalidationMonitor === cache.value.invalidationMonitor)
        let dirty = NativeSettleFixture(); dirty.dirtyMonitor = true
        let dirtyCache = try await dirty.settle()!
        check("ready native cache is returned despite dirty invalidation monitor", dirtyCache.value.invalidationMonitor.state.layoutChanged)
        let busy = NativeSettleFixture(); busy.rows.set(busy.child, name: "AXLoaded", value: .init(raw: kCFBooleanFalse!))
        busy.onSleep = { n in if n == 2 { busy.rows.set(busy.child, name: "AXLoaded", value: .init(raw: kCFBooleanTrue!)) } }
        let ready = try await busy.settle()!
        check("busy native attempt is rebuilt with a fresh tree and monitor", busy.monitors.count == 2 && busy.transactions.count == 2 && busy.intervals == [0.3, 0.3])
        check("ready attempt returns second native monitor and current loaded value", ready.value.invalidationMonitor === busy.monitors[1] && ready.value.tree.preorder.last?.node.element.cachedAttribute("AXLoaded") as? Bool == true)
        let unsupported = NativeSettleFixture()
        unsupported.rows.set(unsupported.child, ["AXRole": .init(raw: "AXWebArea" as NSString), "AXElementBusy": .init(raw: kCFBooleanTrue!), "AXChildren": .init(raw: [] as NSArray)])
        check("native WebArea missing loaded attribute skips element-busy check", try await unsupported.settle() != nil)
        let cancelled = NativeSettleFixture(); cancelled.cancelled = true
        check("native cancellation still owns observation but creates no tree resources", try await cancelled.settle() == nil && cancelled.observation?.stops == 1 && cancelled.monitors.isEmpty && cancelled.transactions.isEmpty)
        let activity = ControllerUISettleActivity<SettingsNativeAXElement>(now: 0)
        activity.receive("AXTitleChanged", key: f.child, title: { "same" }, now: { 1 })
        activity.receive("AXTitleChanged", key: .init(element: AXUIElementCreateApplication(74003)), title: { "same" }, now: { 2 })
        check("native title deduplication keys share AX equality across wrappers", activity.quietAge(now: { 3 }) == 2)
        let retained = ControllerNativeSettleTitleReader(lookup: { _ in nil }, ordinaryPID: { _ in nil },
            raw: { _ in .init(status: AXError.cannotComplete.rawValue, value: .init(raw: "retained" as NSString)) })
        check("native title callback preserves returned string despite raw error status", retained.title(f.child) == "retained")
        let malformed = ControllerNativeSettleTitleReader(lookup: { _ in nil }, ordinaryPID: { _ in nil },
            raw: { _ in .init(status: 0, value: .init(raw: NSNumber(value: 3))) })
        check("native title callback rejects non-string responses", malformed.title(f.child) == nil)
        let missing = ControllerNativeSettleTitleReader(lookup: { _ in nil }, ordinaryPID: { _ in nil }, raw: { _ in .init(status: 0, value: nil) })
        check("native title callback preserves nil successful response", missing.title(f.child) == nil)
        let hosted = ControllerNativeSettleTitleReader(lookup: f.resources.io.lookup, ordinaryPID: { _ in preconditionFailure("Hosted PID must not fall through") },
            raw: { _ in preconditionFailure("Hosted title must not fall through") })
        check("native title callback uses hosted provider before raw PID and value", hosted.title(f.child) == "Content")
        let titleKey = f.child
        let selfRead = ControllerNativeSettleTitleReader(lookup: { _ in nil }, ordinaryPID: { _ in getpid() },
            raw: { _ in .init(status: 0, value: .init(raw: (Thread.isMainThread ? "main" : "worker") as NSString)) })
        let selfTitle = await Task.detached { selfRead.title(titleKey) }.value
        check("native self-process title read dispatches from worker to real main thread", selfTitle == "main")
        let foreignRead = ControllerNativeSettleTitleReader(lookup: { _ in nil }, ordinaryPID: { _ in getpid() + 1 },
            raw: { _ in .init(status: 0, value: .init(raw: (Thread.isMainThread ? "main" : "worker") as NSString)) })
        let foreignTitle = await Task.detached { foreignRead.title(titleKey) }.value
        check("native other-process title read stays on observer worker", foreignTitle == "worker")
        let coupled = ControllerUISettleActivity<SettingsNativeAXElement>(now: 0)
        let callback = try startCoupledCallback(coupled, key: titleKey, reader: selfRead)
        let coupledAge = await ControllerNativeSettleActivitySampling.age(coupled)
        let callbackRecorded = await callback.value
        check("quiet sampling leaves main free for a self-title callback holding the activity lock", callbackRecorded && coupledAge >= 0)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "native_settle_capture_and_cache_consumer_data_adapters_executed": true,
            "clock_observation_monitor_and_transaction_providers_injected": true,
            "actual_AX_observer_hierarchy_query_write_input_focus_cursor_window_capture_or_preferences": false,
            "production_service_entry_executed": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native settle bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
