import AppKit
import ApplicationServices
import Foundation
import os

private final class ClickBindingLease: ControllerOwnerLifetime, @unchecked Sendable { func cancel() {} }
private final class ClickBindingObservation: ControllerOwnerAXObservation, Sendable {
    typealias Node = ControllerNativeElementContext.Node
    func registerDestroyed(_ node: Node) throws {}
    func removeDestroyed(_ node: Node) throws {}
}
private final class ClickBindingOrdering: ControllerOwnerOrdering, @unchecked Sendable {
    var observedWindowIDs: [UInt32] = []
    func start() { preconditionFailure("No ordering task") }
    func stop() {}
    func menuDidOpen() { preconditionFailure("No menu task") }
    func menuDidClose() { preconditionFailure("No menu task") }
}
private final class ClickBridgeRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    func set(_ key: SettingsNativeAXElement, _ values: [String: ControllerNativeAXValue]) { lock.withLock { rows[key] = values } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { rows[key] ?? [:] } }
}
private final class ClickBindingBridge: ControllerNativeElementBridge, Sendable {
    let rows: ClickBridgeRows, key: SettingsNativeAXElement
    init(_ rows: ClickBridgeRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
    var ordinaryPID: Int32 { getpid() }; var actualPID: Int32 { 0 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    func supported() -> Set<String> { Set(rows.values(key).keys) }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { rows.values(key).filter { attributes.contains($0.key) } }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { rows.values(key)[attribute] }
    func perform(_ action: String) throws { preconditionFailure("No AX action") }
    func actions() -> [String] { [] }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { false }
    func setBoolean(_ attribute: String, _ value: Bool) throws { preconditionFailure("No AX write") }
}
@MainActor private final class NativeClickDataFixture {
    typealias Node = ControllerNativeElementContext.Node
    let rows = ClickBridgeRows()
    let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(71001))
    let bar = SettingsNativeAXElement(element: AXUIElementCreateApplication(71002))
    let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(71003))
    let menu = SettingsNativeAXElement(element: AXUIElementCreateApplication(71004))
    let group = SettingsNativeAXElement(element: AXUIElementCreateApplication(71005))
    let otherMenu = SettingsNativeAXElement(element: AXUIElementCreateApplication(71006))
    let resources: ControllerNativeResources
    init() {
        let rows = rows
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 0, windowID: 51, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No input") })
        resources = .init(context: context, lookup: { ClickBindingBridge(rows, $0) }, windowServer: ws)
        rows.set(app, ["AXRole": .init(raw: "AXApplication" as NSString)])
        rows.set(window, ["AXRole": .init(raw: "AXWindow" as NSString)])
        rows.set(bar, ["AXRole": .init(raw: "AXMenuBarItem" as NSString), "AXChildren": .init(raw: [group.element, menu.element, otherMenu.element] as NSArray)])
        rows.set(group, ["AXRole": .init(raw: "AXGroup" as NSString), "AXChildren": .init(raw: [otherMenu.element] as NSArray)])
        rows.set(menu, ["AXRole": .init(raw: "AXMenu" as NSString)])
        rows.set(otherMenu, ["AXRole": .init(raw: "AXMenu" as NSString)])
    }
    func node(_ key: SettingsNativeAXElement) -> Node { resources.context.context.node(key) }
    func raw(_ key: SettingsNativeAXElement) -> EventStreamAXNode { ControllerNativeAppSnapshotContext.snapshotNode(node(key), context: resources.context) }
    func selection(windowID: UInt32, windowKey: SettingsNativeAXElement? = nil) throws -> ControllerNativeAppSnapshotSelection {
        var transformed = EventStreamTransformedNode(element: raw(bar)); transformed.role = "AXMenuBarItem"
        let tree = EventStreamCollectedTree(roots: [EventStreamCollectedItem(node: transformed, path: [0], children: [], childrenSubset: nil)])
        let revision = try EventStreamNativeTreeRevision.Revision.root(tree, lineageID: UUID().uuidString, identity: { .init(element: $0.element) }, render: { _ in
            .init(isFocusTree: false, roots: [.init(identity: .init(element: self.bar.element), text: "Menu: fixture", sourcePath: [0])])
        })
        let native = EventStreamNativeWindow(id: windowID, processIdentifier: getpid(), frame: .init(x: 0, y: 0, width: 100, height: 100), level: 0, title: "data", ownerName: "owned")
        let selectedWindow = windowKey ?? window
        let a = raw(app), w = raw(selectedWindow)
        let source = ControllerNativeAppSnapshotSource(context: .init(application: a, window: w, focusedElement: nil, nativeWindow: native), window: node(selectedWindow))
        return .init(.init(applicationWindow: .init(application: a, window: w, nativeWindow: native), windowRevision: revision, invalidationMonitor: nil, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: source)
    }
    func owner() throws -> ControllerNativeAppSnapshotBackend.Owner {
        typealias Owner = ControllerNativeAppSnapshotBackend.Owner
        let app = node(app), order = ClickBindingOrdering()
        let environment = Owner.Environment(resolveIdentity: { _ in (.init(application: .current), getpid()) }, makeApplicationNode: { _ in app }, makeOrdering: { _ in order },
            makeSignposter: { OSSignposter(subsystem: "local.cua.fixture", category: "readonly") }, primaryWindow: { _ in nil }, children: { _ in [] }, role: { _ in "AXApplication" },
            windowID: { _ in 51 }, menuWindowID: { _ in 51 }, actualPID: { _ in getpid() }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { _ in preconditionFailure("No attention") }, observeTermination: { _ in ClickBindingLease() }, terminatedPID: { _ in nil },
            observeAX: { _, _, _ in ClickBindingObservation() }, registerWeakOwner: { _ in }, notificationCenter: NotificationCenter(), analytics: { _ in preconditionFailure("No analytics") },
            acquireAccessibility: { _ in preconditionFailure("No AX acquisition") }, releaseAccessibility: { _ in preconditionFailure("No AX release") },
            makeFocusEnforcer: { _ in preconditionFailure("No focus construction") }, deactivateFocusEnforcer: { _ in preconditionFailure("No focus") },
            setFocusEnforcerPID: { _, _ in preconditionFailure("No menu suppression") }, clearFocusEnforcerPID: { _ in preconditionFailure("No menu suppression") },
            scheduleOnMainActor: { _ in preconditionFailure("No cleanup task") }, orderOutCursor: { _ in preconditionFailure("No cursor hide") }, now: { Date() }, sleep: { _ in preconditionFailure("No readiness wait") })
        return try .init(target: .init(bundleIdentifier: "local.cua.click.fixture", url: URL(fileURLWithPath: "/private/tmp/click-fixture.app")), chatID: nil, mcpRuntime: 2, isAXTreeDiffingEnabled: true, environment: environment)
    }
    func element(_ key: SettingsNativeAXElement, tree: ControllerRefetchableAppSnapshotTree) -> ControllerNativeResolvedElement {
        var node = EventStreamTransformedNode(element: raw(key)); node.role = resources.context.context.role(self.node(key))
        let io = ControllerNativeRefetchIO(roleStatus: { _ in preconditionFailure("No role probe") }, fresh: { _ in preconditionFailure("No fresh AX read") }, capture: { _, _ in preconditionFailure("No AX recapture") })
        return .init(node: node, tree: tree, resources: resources, io: io)
    }
}
@MainActor private final class ClickRuntimeSink {
    var calls = 0, settles = 0, flags: ControllerClickDelivery?, context: ControllerNativeClickContext?, cursor: ControllerApprovedCursor?
    var settleApplication: ControllerNativeElementContext.Node?, delay: Double?, notificationDelay = 0.0, includeScroll = true
}
private enum NativeClickBindingError: Error { case delivery }
@MainActor enum NativeClickBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        let f = NativeClickDataFixture(), owner = try f.owner()
        let controller = ControllerNativeAppController(owner: owner, resources: f.resources)
        check("native click entry retains already composed owner and resources", controller.owner === owner && controller.resources === f.resources)
        check("composed native click owner remains inactive without focus assertion or cursor", !owner.isActive && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil && owner.virtualCursor == nil)
        let freshWindow = SettingsNativeAXElement(element: AXUIElementCreateApplication(71008))
        f.rows.set(freshWindow, ["AXRole": .init(raw: "AXWindow" as NSString)])
        let initial = try f.selection(windowID: 51), replacement = try f.selection(windowID: 99, windowKey: freshWindow)
        let tree = ControllerRefetchableAppSnapshotTree(selection: initial, isAXTreeDiffingEnabled: true)
        let element = f.element(f.bar, tree: tree)
        let nativeMenu = ControllerNativeMenuInteraction(owner: owner, resources: f.resources)
        check("native menu lookup selects first direct AXMenu child", nativeMenu.childMenu(element)?.element == f.menu)
        let groupElement = f.element(f.group, tree: tree)
        check("native menu lookup requires AXMenuBarItem role", nativeMenu.childMenu(groupElement) == nil)
        let deep = SettingsNativeAXElement(element: AXUIElementCreateApplication(71007))
        f.rows.set(deep, ["AXRole": .init(raw: "AXMenuBarItem" as NSString), "AXChildren": .init(raw: [f.group.element] as NSArray)])
        check("native menu lookup does not search descendants beyond direct children", nativeMenu.childMenu(f.element(deep, tree: tree)) == nil)
        nativeMenu.setFocusedMenuBarItem(element); nativeMenu.setOpenedMenu(f.node(f.menu))
        check("native menu publishes actual focused bar item and opened menu separately", owner.currentlyFocusedMenuBarItem?.element == f.bar && owner.currentlyOpenedMenu?.element == f.menu)
        check("native menu window reads tree source without global-window fallback", nativeMenu.window(tree).element == f.window)
        ControllerMenuInteraction(backend: nativeMenu).clearIfMenuBarItem(f.node(f.menu))
        check("native non-bar menu does not clear owner fields", owner.currentlyFocusedMenuBarItem?.element == f.bar && owner.currentlyOpenedMenu?.element == f.menu)
        ControllerMenuInteraction(backend: nativeMenu).clearIfMenuBarItem(f.node(f.bar))
        check("native bar-item clear resets both owner menu fields", owner.currentlyFocusedMenuBarItem == nil && owner.currentlyOpenedMenu == nil)
        let sink = ClickRuntimeSink(), cursor = ControllerApprovedCursor()
        let runtime = ControllerNativeClickRuntime(click: { _, captured, delivery, passedCursor in
            sink.calls += 1; sink.context = captured; sink.flags = delivery; sink.cursor = passedCursor
            await Task.yield(); tree.selection = replacement
        }, settle: { application, delay, notificationDelay, scroll in
            sink.settles += 1; sink.settleApplication = application; sink.delay = delay; sink.notificationDelay = notificationDelay; sink.includeScroll = scroll
            await Task.yield(); return nil
        })
        let backend = ControllerNativeClickBackend(controller: controller, runtime: runtime)
        let delivery = ControllerClickDelivery(button: .right, count: 2, hold: .zero, key: try .parse("ctrl+A"), alwaysSimulate: true)
        try await backend.click(element, tree: tree, delivery: delivery, cursor: cursor)
        check("native click forwards parsed count button hold and simulation", sink.flags?.button == .right && sink.flags?.count == 2 && sink.flags?.hold == .zero && sink.flags?.alwaysSimulate == true)
        check("native click forwards physical key and complete modifier flags", sink.flags?.key == .init(keyCode: 0, carbonModifiers: 4608, eventFlags: 393216))
        check("native click retains supplied cursor across runtime await", sink.cursor === cursor && owner.virtualCursor == nil)
        check("native click snapshots application window and optional focus before runtime suspension", sink.context?.application.element == f.app && sink.context?.window.element == f.window && sink.context?.focus == nil && tree.selection === replacement && tree.selection.value.applicationWindow.window.element == freshWindow.element)
        backend.needsUISettleBeforeAppSnapshot = true
        check("native click deferred-settle flag updates actual owner", owner.needsUISettleBeforeAppSnapshot && backend.needsUISettleBeforeAppSnapshot)
        let cache = try await backend.settle(delay: 0.1, notificationDelay: 0.25, includingScrollEvents: false)
        check("native settle forwards owner app and exact timing options", sink.settleApplication?.element == f.app && sink.delay == 0.1 && sink.notificationDelay == 0.25 && !sink.includeScroll)
        check("native settle preserves nil provider cache and leaves caller-owned flag alone", cache == nil && owner.needsUISettleBeforeAppSnapshot)
        nativeMenu.setFocusedMenuBarItem(element)
        check("native click tracked-menu getter uses actual owner", backend.focusedMenuBarItem?.element == f.bar)
        await backend.clearMenuIfMenuBarItem(f.node(f.bar))
        check("native click tracked-menu clear delegates to owner bindings", owner.currentlyFocusedMenuBarItem == nil)
        var invalid = ControllerClickParameters(elementID: 0); invalid.key = "unknown"
        var invalidCaught = false
        do { _ = try await controller.click(invalid, runtime: runtime) } catch ControllerHeldClickKeyFailure.unknownSymbol { invalidCaught = true }
        check("actual native controller entry parses invalid key before any AX preparation", invalidCaught && sink.calls == 1 && owner.focusEnforcer == nil)
        var missingTree = false
        do { _ = try await controller.click(.init(elementID: 0), runtime: runtime) } catch ControllerInteractionPreparationFailure.missingAppSnapshotTree { missingTree = true }
        check("actual native controller entry requires appSnapshot before focus or click", missingTree && sink.calls == 1 && owner.focusEnforcer == nil)
        let failing = ControllerNativeClickRuntime(click: { _, _, _, _ in throw NativeClickBindingError.delivery }, settle: runtime.settle)
        var propagated = false
        do { try await ControllerNativeClickBackend(controller: controller, runtime: failing).click(element, tree: tree, delivery: delivery, cursor: nil) } catch NativeClickBindingError.delivery { propagated = true }
        check("native click adapter propagates lower delivery error without mapping it", propagated)
        check("native async data fixture leaves owner inactive without native effects", !owner.isActive && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil && owner.virtualCursor == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "native_owner_menu_and_click_runtime_bindings_executed": true, "effect_environment_and_lower_click_settle_providers_injected": true,
            "actual_AX_query_write_focus_input_cursor_window_screen_capture_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native click/menu bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
