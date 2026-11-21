import AppKit
import ApplicationServices
import Foundation
import os

enum SecondaryScrollDataNativeFailure: Error { case observer }
final class SecondaryScrollDataRows: @unchecked Sendable {
    let lock = NSLock()
    var storedNames: [String] = ["AXPress", "AXFixtureCustomAction"]
    func setNames(_ names: [String]) { lock.withLock { storedNames = names } }
    var names: [String] { lock.withLock { storedNames } }
    var actionLog: [String] = []
    func record(_ action: String) { lock.withLock { actionLog.append(action) } }
    var actions: [String] { lock.withLock { actionLog } }
    var stored: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] = [:]
    func set(_ key: SettingsNativeAXElement, _ values: [String: ControllerNativeAXValue]) { lock.withLock { stored[key] = values } }
    func set(_ key: SettingsNativeAXElement, name: String, value: ControllerNativeAXValue) { lock.withLock { stored[key, default: [:]][name] = value } }
    func values(_ key: SettingsNativeAXElement) -> [String: ControllerNativeAXValue] { lock.withLock { stored[key] ?? [:] } }
    var table: [SettingsNativeAXElement: [String: ControllerNativeAXValue]] { lock.withLock { stored } }
}
final class SecondaryScrollDataBridge: ControllerNativeSettleRichBridge, ControllerNativeMouseHitTestBridge, Sendable {
    let rows: SecondaryScrollDataRows, key: SettingsNativeAXElement
    init(_ rows: SecondaryScrollDataRows, _ key: SettingsNativeAXElement) { self.rows = rows; self.key = key }
    var ordinaryPID: Int32 { 74001 }; var actualPID: Int32 { 74001 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    func supported() -> Set<String> { Set(rows.values(key).keys) }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { rows.values(key).filter { attributes.contains($0.key) } }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { rows.values(key)[attribute] }
    func perform(_ action: String) throws { rows.record(action) }
    func element(at point: CGPoint) throws -> SettingsNativeAXElement? {
        if let code = rows.values(key)["AXFixtureHitError"]?.raw as? NSNumber { throw ControllerNativeElementDecoding.Failure.accessibility(code.int32Value) }
        guard let raw = rows.values(key)["AXFixtureHit"] else { return nil }; return .init(element: unsafeDowncast(raw.raw, to: AXUIElement.self))
    }
    func actions() -> [String] { rows.names }
    func count(_ attribute: String) -> Int? { (rows.values(key)[attribute]?.raw as? [AnyObject])?.count }
    func isSettable(_ attribute: String) -> Bool { false }
    func setBoolean(_ attribute: String, _ value: Bool) throws { preconditionFailure("No AX write") }
    func actionDescription(_ name: String) throws -> String? { "Hosted action" }
    func string(for range: NSRange) throws -> String? { nil }
}
@MainActor final class SecondaryScrollDataObservation: ControllerNativeSettleObservation {
    let activity = ControllerUISettleActivity<Int>(now: 0)
    var stops = 0
    func quietAge(now: () -> Double) -> Double { activity.quietAge(now: now) }
    func stop() { stops += 1 }
}
@MainActor final class SecondaryScrollDataNativeFixture {
    typealias Node = ControllerNativeElementContext.Node
    let rows = SecondaryScrollDataRows()
    let app = SettingsNativeAXElement(element: AXUIElementCreateApplication(74001))
    let window = SettingsNativeAXElement(element: AXUIElementCreateApplication(74002))
    let child = SettingsNativeAXElement(element: AXUIElementCreateApplication(74003))
    let resources: ControllerNativeResources
    var time = 0.0, cancelled = false, shapeReads = 0, monitors: [EventStreamTreeInvalidationMonitor] = []
    var transactions: [EventStreamNativeTreeTransaction] = [], observation: SecondaryScrollDataObservation?, names: [String] = [], trace: [String] = []
    var intervals: [Double] = [], onSleep: ((Int) -> Void)?, dirtyMonitor = false
    init() {
        let rows = rows
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in .init(actualPID: 74001, windowID: 51, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS mutation") }, reenable: { _ in preconditionFailure("No WS mutation") }, setLocation: { _, _ in preconditionFailure("No event") })
        resources = .init(context: context, lookup: { SecondaryScrollDataBridge(rows, $0) }, windowServer: ws, actions: .init())
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
            self.names = names; let observation = SecondaryScrollDataObservation(); self.observation = observation; return observation
        }, monitor: { node in
            self.trace.append("monitor")
            let monitor = EventStreamTreeInvalidationMonitor(application: node.element.element, io: .init(processIdentifier: { _ in throw SecondaryScrollDataNativeFailure.observer }, observer: { _, _ in preconditionFailure("No AX observer") }))
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

final class SecondaryScrollDataLease: ControllerOwnerLifetime, @unchecked Sendable { func cancel() {} }
final class SecondaryScrollDataOwnerObservation: ControllerOwnerAXObservation, Sendable {
    typealias Node = ControllerNativeElementContext.Node
    func registerDestroyed(_ node: Node) throws {}
    func removeDestroyed(_ node: Node) throws {}
}
final class SecondaryScrollDataOrdering: ControllerOwnerOrdering, @unchecked Sendable {
    var observedWindowIDs: [UInt32] = []
    func start() { preconditionFailure("No ordering task") }
    func stop() {}
    func menuDidOpen() { preconditionFailure("No menu effect") }
    func menuDidClose() { preconditionFailure("No menu effect") }
}
final class SecondaryScrollDataError: Error, @unchecked Sendable {}

@MainActor enum NativeSecondaryScrollDataAppSnapshotBindingChecks {
    static func owner(_ fixture: SecondaryScrollDataNativeFixture) throws -> ControllerNativeAppSnapshotBackend.Owner {
        typealias Owner = ControllerNativeAppSnapshotBackend.Owner
        let app = fixture.application, ordering = SecondaryScrollDataOrdering()
        let environment = Owner.Environment(resolveIdentity: { _ in (.init(application: .current), getpid()) },
            makeApplicationNode: { _ in app }, makeOrdering: { _ in ordering },
            makeSignposter: { OSSignposter(subsystem: "local.cua.fixture", category: "deferred") },
            primaryWindow: { _ in nil }, children: { _ in [] }, role: { _ in "AXApplication" },
            windowID: { _ in 51 }, menuWindowID: { _ in 51 }, actualPID: { _ in 74001 }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { _ in preconditionFailure("No attention") }, observeTermination: { _ in SecondaryScrollDataLease() },
            terminatedPID: { _ in nil }, observeAX: { _, _, _ in SecondaryScrollDataOwnerObservation() }, registerWeakOwner: { _ in },
            notificationCenter: NotificationCenter(), analytics: { _ in preconditionFailure("No analytics") },
            acquireAccessibility: { _ in preconditionFailure("No AX enablement") }, releaseAccessibility: { _ in preconditionFailure("No AX release") },
            makeFocusEnforcer: { _ in preconditionFailure("No focus") }, deactivateFocusEnforcer: { _ in preconditionFailure("No focus") },
            setFocusEnforcerPID: { _, _ in preconditionFailure("No focus") }, clearFocusEnforcerPID: { _ in preconditionFailure("No focus") },
            scheduleOnMainActor: { _ in preconditionFailure("No cleanup task") }, orderOutCursor: { _ in preconditionFailure("No cursor") },
            now: { Date() }, sleep: { _ in preconditionFailure("No readiness sleep") })
        return try .init(target: .init(bundleIdentifier: "local.cua.deferred.fixture", url: URL(fileURLWithPath: "/private/tmp/deferred-fixture.app")),
            chatID: nil, mcpRuntime: 2, isAXTreeDiffingEnabled: true, environment: environment)
    }
    static func result(_ f: SecondaryScrollDataNativeFixture) throws -> ControllerNativeAppController.AppSnapshot {
        let window = f.resources.context.context.node(f.window)
        let raw = ControllerNativeAppSnapshotContext.snapshotNode(window, context: f.resources.context)
        var transformed = EventStreamTransformedNode(element: raw); transformed.role = "AXWindow"
        transformed.actionDescriptions = [.init(name: "AXFixtureAction", description: "Published title")]
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
}
