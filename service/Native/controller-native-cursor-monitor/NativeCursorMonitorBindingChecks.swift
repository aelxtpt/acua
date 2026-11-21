import AppKit
import ApplicationServices
import Foundation
import os

private enum CursorDataNativeFailure: Error { case observer }
private final class CursorDataRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    func set(_ key: SettingsNativeAXElement, _ values: [String: ControllerNativeAXValue]) { lock.withLock { stored[key] = values } }
    func set(_ key: SettingsNativeAXElement, name: String, value: ControllerNativeAXValue) { lock.withLock { stored[key, default: [:]][name] = value } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { stored[key] ?? [:] } }
    var table: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] { lock.withLock { stored } }
}
private final class CursorDataBridge: ControllerNativeSettleRichBridge, Sendable {
    let rows: CursorDataRows, key: SettingsNativeAXElement
    init(_ rows: CursorDataRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
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
@MainActor private final class CursorDataObservation: ControllerNativeSettleObservation {
    let activity = ControllerUISettleActivity<Int>(now: 0)
    var stops = 0
    func quietAge(now: () -> Double) -> Double { activity.quietAge(now: now) }
    func stop() { stops += 1 }
}
@MainActor private final class CursorDataNativeFixture {
    typealias Node = ControllerNativeElementContext.Node
    let rows = CursorDataRows()
    let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(74001))
    let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(74002))
    let child = SettingsNativeAXElement(element: AXUIElementCreateApplication(74003))
    let resources: ControllerNativeResources
    var time = 0.0, cancelled = false, shapeReads = 0, monitors: [EventStreamTreeInvalidationMonitor] = []
    var transactions: [EventStreamNativeTreeTransaction] = [], observation: CursorDataObservation?, names: [String] = [], trace: [String] = []
    var intervals: [Double] = [], onSleep: ((Int) -> Void)?, dirtyMonitor = false
    init() {
        let rows = rows
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 74001, windowID: 51, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No event") })
        resources = .init(context: context, lookup: { CursorDataBridge(rows, $0) }, windowServer: ws, actions: .init())
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
            self.names = names; let observation = CursorDataObservation(); self.observation = observation; return observation
        }, monitor: { node in
            self.trace.append("monitor")
            let monitor = EventStreamTreeInvalidationMonitor(application: node.element.element, io: .init(processIdentifier: { _ in throw CursorDataNativeFailure.observer }, observer: { _, _ in preconditionFailure("No AX observer") }))
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

private final class CursorDataLease: ControllerOwnerLifetime, @unchecked Sendable { func cancel() {} }
private final class CursorDataOwnerObservation: ControllerOwnerAXObservation, Sendable {
    typealias Node = ControllerNativeElementContext.Node
    func registerDestroyed(_ node: Node) throws {}
    func removeDestroyed(_ node: Node) throws {}
}
private final class CursorDataOrdering: ControllerOwnerOrdering, @unchecked Sendable {
    var observedWindowIDs: [UInt32] = []
    func start() { preconditionFailure("No ordering task") }
    func stop() {}
    func menuDidOpen() { preconditionFailure("No menu effect") }
    func menuDidClose() { preconditionFailure("No menu effect") }
}
private final class CursorDataError: Error, @unchecked Sendable {}

@MainActor enum NativeCursorMonitorBindingChecks {
    /// Separate bounded UI mode: real hidden/near-transparent owned panels,
    /// read-only Finder observation and no physical input or screenshot.
    static func runWindow(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name":name,"passed":value]); if !value { print("FAIL: " + name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cursor = ControllerApprovedCursor(); cursor.prepare()
        let panel = cursor.windowForMonitoring()
        let target = NSPanel(contentRect: .init(x:80,y:300,width:240,height:140),
            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        target.isReleasedWhenClosed = false; target.ignoresMouseEvents = true; target.alphaValue = 0.001
        panel.alphaValue = 0.001; panel.setFrameOrigin(target.frame.origin)
        defer { panel.monitorWindow.appMonitor = nil; cursor.hide(); panel.close(); target.close() }
        check("real approved cursor window prepares hidden without foreground activation", !panel.isVisible && cursor.visibleWindowID == nil)
        var axStarted = false, axStopped = false, kvoStarted = false, kvoStopped = false
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first,
           let ws = ControllerNativeWindowServer.resolve() {
            let context = ControllerNativeElementContext(currentTransaction:{ nil },lookup:{ _ in nil },log:{ _,_ in })
            let resources = ControllerNativeResources(context:context,lookup:{ _ in nil },windowServer:ws)
            let native = ControllerNativeCursorAppMonitor.nativeEnvironment(resources:resources)
            let observed = ControllerNativeCursorAppMonitor.Environment(runningApplication:native.runningApplication,
                isActive:native.isActive,primaryWindow:native.primaryWindow,windowID:native.windowID,
                isVisible:native.isVisible,setApplicationOverlayReason:native.setApplicationOverlayReason,retargetVisibleWindow:native.retargetVisibleWindow,
                observeAX:{ app,pid,names,callback in
                    let lease = try native.observeAX(app,pid,names,callback); axStarted = true
                    return ControllerCursorNativeLease { lease.stop(); axStopped = true }
                },observeActive:{ app,callback in
                    let lease = native.observeActive(app,callback); kvoStarted = true
                    return ControllerCursorNativeLease { lease.stop(); kvoStopped = true }
                },enqueue:native.enqueue)
            panel.monitorWindow.appMonitor = .init(application:resources.context.application(finder.processIdentifier),
                pid:finder.processIdentifier,window:panel.monitorWindow,environment:observed)
            check("real native AppMonitor resolves running target and installs AX plus KVO", panel.monitorWindow.appMonitor != nil && axStarted && kvoStarted)
            panel.monitorWindow.appMonitor = nil
            try await Task.sleep(for:.milliseconds(80))
            check("real native AppMonitor releases AX and KVO observation", axStopped && kvoStopped)
        } else { check("real native AppMonitor target and WindowServer symbols exist", false) }
        panel.monitorWindow.setApplicationReason(false)
        target.orderFrontRegardless()
        try await Task.sleep(for:.milliseconds(80))
        let targetID = UInt32(target.windowNumber)
        panel.showForCursor(relativeTo:targetID,temporaryOverlay:false)
        check("native relative ordering displays owned cursor at target level", panel.isVisible && panel.level == target.level)
        panel.monitorWindow.setApplicationReason(true)
        check("native application reason raises owned panel to level 102", panel.level.rawValue == 102)
        let info = WindowDescription.lookup(UInt32(panel.windowNumber))
        check("actual WindowServer record reflects the overlay level", (info?[kCGWindowLayer as String] as? NSNumber)?.intValue == 102)
        panel.monitorWindow.setApplicationReason(false)
        check("native deactivation restores target level", panel.level == target.level)
        panel.showForCursor(relativeTo:targetID,temporaryOverlay:true)
        check("native temporary movement reason elevates panel independently", panel.level.rawValue == 102)
        let tip = CGPoint(x:panel.frame.minX + panel.tipOffset.x,y:panel.frame.minY + panel.tipOffset.y)
        let below = NSWindow.windowNumber(at:tip,belowWindowWithWindowNumber:panel.windowNumber)
        panel.cursorMoved()
        check("native movement overlay follows actual window below the tip", panel.level.rawValue == (below == Int(targetID) ? target.level.rawValue : 102))
        cursor.hide()
        check("real cursor hide clears visible-window identity", !panel.isVisible && cursor.visibleWindowID == nil)
        check("owned native window test preserves foreground", foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,
            "actual_owned_native_cursor_panel_and_window_ordering_executed":true,
            "actual_AX_and_KVO_target_observation_attempted":true,
            "actual_AX_observation_started":axStarted,"actual_KVO_observation_started":kvoStarted,
            "actual_AX_observation_stopped":axStopped,"actual_KVO_observation_stopped":kvoStopped,
            "owned_cursor_window_id":panel.windowNumber,"owned_target_window_id":targetID,
            "overlay_window_server_layer":info?[kCGWindowLayer as String] ?? NSNull(),"actual_window_below_tip":below,
            "physical_mouse_keyboard_screen_capture_focus_AX_action_or_preferences":false,
            "owned_panels_close_on_return":true],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native cursor owned-window checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
    private static func makeOwner(_ fixture: CursorDataNativeFixture) throws -> ControllerNativeAppSnapshotBackend.Owner {
        typealias Owner = ControllerNativeAppSnapshotBackend.Owner
        let app = fixture.application, ordering = CursorDataOrdering()
        let environment = Owner.Environment(resolveIdentity: { _ in (.init(application: .current), getpid()) },
            makeApplicationNode: { _ in app }, makeOrdering: { _ in ordering },
            makeSignposter: { OSSignposter(subsystem: "local.cua.fixture", category: "deferred") },
            primaryWindow: { _ in nil }, children: { _ in [] }, role: { _ in "AXApplication" },
            windowID: { _ in 51 }, menuWindowID: { _ in 51 }, actualPID: { _ in 74001 }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { _ in preconditionFailure("No attention") }, observeTermination: { _ in CursorDataLease() },
            terminatedPID: { _ in nil }, observeAX: { _, _, _ in CursorDataOwnerObservation() }, registerWeakOwner: { _ in },
            notificationCenter: NotificationCenter(), analytics: { _ in preconditionFailure("No analytics") },
            acquireAccessibility: { _ in preconditionFailure("No AX enablement") }, releaseAccessibility: { _ in preconditionFailure("No AX release") },
            makeFocusEnforcer: { _ in preconditionFailure("No focus") }, deactivateFocusEnforcer: { _ in preconditionFailure("No focus") },
            setFocusEnforcerPID: { _, _ in preconditionFailure("No focus") }, clearFocusEnforcerPID: { _ in preconditionFailure("No focus") },
            scheduleOnMainActor: { _ in preconditionFailure("No cleanup task") }, orderOutCursor: { _ in preconditionFailure("No cursor") },
            now: { Date() }, sleep: { _ in preconditionFailure("No readiness sleep") })
        return try .init(target: .init(bundleIdentifier: "local.cua.deferred.fixture", url: URL(fileURLWithPath: "/private/tmp/deferred-fixture.app")),
            chatID: nil, mcpRuntime: 2, isAXTreeDiffingEnabled: true, environment: environment)
    }
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let f = CursorDataNativeFixture(), owner = try makeOwner(f)
        let controller = ControllerNativeAppController(owner: owner, resources: f.resources)
        let state = CursorDataWindowState(), jobs = CursorDataJobs(), axLease = CursorDataMonitorLease(), kvoLease = CursorDataMonitorLease()
        var window: ControllerCursorMonitorWindow? = .init(isVisible: { state.visible },
            setApplicationReason: { state.reasons.append($0) }, retarget: { state.targets.append($0) })
        var names: [String] = [], trace: [String] = [], callbacks: (@Sendable (String) -> Void)?, active: (@Sendable (Bool?) -> Void)?
        var created = 0, windows = 0, monitors = 0, passedPID: Int32?, passedApplication: ControllerNativeElementContext.Node?
        let monitorEnvironment = ControllerNativeCursorAppMonitor.Environment(runningApplication: { _ in .init(application: .current) },
            isActive: { _ in false }, primaryWindow: { f.resources.context.context.primaryWindow($0) },
            windowID: { try f.resources.context.identity.windowID($0.element) }, isVisible: { $0.isVisible() },
            setApplicationOverlayReason: { $0.setApplicationReason($1) }, retargetVisibleWindow: { $0.retarget($1) },
            observeAX: { app, pid, ordered, callback in
                trace.append("AX"); names = ordered; passedPID = pid; passedApplication = app; callbacks = callback; return axLease
            }, observeActive: { _, callback in trace.append("KVO"); active = callback; return kvoLease }, enqueue: { jobs.add($0) })
        let creationEnvironment = ControllerNativeCursorCreationEnvironment(makeCursor: {
            created += 1; trace.append("create"); return ControllerApprovedCursor()
        }, window: { cursor in
            windows += 1; trace.append("window")
            check("native cursor is published before window lookup", owner.virtualCursor === cursor)
            check("native corresponding PID is assigned before monitor-window lookup", cursor.correspondingApplicationPID == owner.pid)
            return window!
        }, application: { pid in
            trace.append("app"); check("native cursor app wrapper uses complete owner PID", pid == owner.pid); return f.application
        }, monitor: { app, pid, handle in
            monitors += 1; trace.append("monitor")
            return .init(application: app, pid: pid, window: handle, environment: monitorEnvironment)
        })
        let cursor = controller.createVirtualCursorIfNeeded(environment: creationEnvironment)
        check("actual native factory publishes same cursor on complete owner", owner.virtualCursor === cursor && created == 1)
        check("native cursor binding retains optional application PID exactly", cursor.correspondingApplicationPID == owner.pid)
        check("native factory builds window then app then monitor", trace == ["create", "window", "app", "monitor", "AX", "KVO"])
        check("native monitor receives exact owner PID and supplied app wrapper", passedPID == owner.pid && passedApplication?.element == f.app)
        check("native monitor observes exactly three AX events", names == ["AXFocusedWindowChanged", "AXMenuOpened", "AXMenuClosed"])
        check("native monitor is retained by same monitor-window handle", window?.appMonitor != nil && window?.appMonitor?.application.element == f.app)
        check("native inactive app initially disables application overlay reason", state.reasons == [false])
        callbacks?("AXMenuOpened"); jobs.drain()
        check("native queued menu event enables window overlay reason", state.reasons == [false,true] && window?.appMonitor?.openMenus == 1)
        callbacks?("AXMenuClosed"); jobs.drain(); active?(true); jobs.drain()
        check("native KVO delivery and menu count share application reason", state.reasons == [false,true,false,true] && window?.appMonitor?.isActive == true)
        callbacks?("AXFocusedWindowChanged"); jobs.drain()
        check("native focused-window delivery uses shared context and cached identity", state.targets == [51])
        state.visible = false; callbacks?("AXFocusedWindowChanged"); jobs.drain()
        check("native focused-window delivery leaves hidden cursor target alone", state.targets == [51])
        let existing = controller.createVirtualCursorIfNeeded()
        check("default native factory reuses existing cursor without new effects", existing === cursor && created == 1 && windows == 1 && monitors == 1)
        let runtime = ControllerNativeClickRuntime.native(resources: f.resources, settleEnvironment: f.environment)
        let click = ControllerNativeClickBackend(controller: controller, runtime: runtime)
        let position = ControllerNativePositionBackend(controller: controller)
        check("native click path reuses centralized bound cursor", click.ensureCursor() === cursor)
        check("native position path reuses same centralized bound cursor", position.ensureCursor() === cursor)
        check("cursor metadata queries still do not allocate native window", cursor.visibleWindowID == nil)
        let weak = CursorDataWeakMonitor(window?.appMonitor)
        callbacks?("AXMenuOpened"); window = nil
        check("queued callback keeps native monitor alive after weak window release", weak.value != nil && axLease.stops == 0)
        jobs.drain()
        check("native monitor releases AX and KVO leases after queued callback", weak.value == nil && axLease.stops == 1 && kvoLease.stops == 1)
        owner.virtualCursor = nil
        let failedWindow = ControllerCursorMonitorWindow(isVisible: { false }, setApplicationReason: { _ in }, retarget: { _ in })
        let failedEnvironment = ControllerNativeCursorCreationEnvironment(makeCursor: { ControllerApprovedCursor() }, window: { _ in failedWindow },
            application: { _ in f.application }, monitor: { _, _, _ in nil })
        let withoutMonitor = controller.createVirtualCursorIfNeeded(environment: failedEnvironment)
        check("failed native monitor does not discard cursor or PID", owner.virtualCursor === withoutMonitor && withoutMonitor.correspondingApplicationPID == owner.pid && failedWindow.appMonitor == nil)
        let defaults = ControllerNativeCursorCreationEnvironment.native(resources: f.resources)
        let native = ControllerNativeCursorCreationBackend(controller: controller, environment: defaults)
        check("default native composition binds existing controller resources", native.controller === controller && native.pid == owner.pid)
        check("native cursor data fixture leaves owner inactive and window-free", !owner.isActive && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil && withoutMonitor.visibleWindowID == nil)
        owner.virtualCursor = nil
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed":passed,"cases":cases,"all_owned_tasks_terminal":true,
            "actual_native_cursor_factory_owner_PID_monitor_and_shared_context_data_adapters_executed":true,
            "cursor_window_running_app_AX_KVO_and_scheduler_providers_injected":true,
            "actual_AX_observer_hierarchy_query_write_input_focus_cursor_window_capture_or_preferences":false,
            "production_service_entry_executed":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native cursor monitor bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
@MainActor private final class CursorDataWindowState { var visible = true; var reasons: [Bool] = []; var targets: [UInt32] = [] }
@MainActor private final class CursorDataWeakMonitor { weak var value: ControllerNativeCursorAppMonitor?; init(_ value: ControllerNativeCursorAppMonitor?) { self.value = value } }
private final class CursorDataMonitorLease: ControllerCursorMonitorLease, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func stop() { lock.withLock { count += 1 } }
    var stops: Int { lock.withLock { count } }
}
private final class CursorDataJobs: @unchecked Sendable {
    private let lock = NSLock(); private var values: [@MainActor @Sendable () -> Void] = []
    func add(_ value: @escaping @MainActor @Sendable () -> Void) { lock.withLock { values.append(value) } }
    @MainActor func drain() { while let work = lock.withLock({ values.isEmpty ? nil : values.removeFirst() }) { work() } }
}
