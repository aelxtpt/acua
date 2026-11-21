import AppKit
import ApplicationServices
import Foundation
import os

private final class BindingLease: ControllerOwnerLifetime, @unchecked Sendable { func cancel() {} }
private final class BindingObservation: ControllerOwnerAXObservation, Sendable {
    typealias Node = ControllerNativeElementContext.Node
    func registerDestroyed(_ node: Node) throws {}
    func removeDestroyed(_ node: Node) throws {}
}
private final class BindingOrdering: ControllerOwnerOrdering, @unchecked Sendable {
    var observedWindowIDs: [UInt32] = []
    func start() { preconditionFailure("No ordering task admitted") }
    func stop() {}
    func menuDidOpen() { preconditionFailure("No menu task admitted") }
    func menuDidClose() { preconditionFailure("No menu task admitted") }
}
@MainActor enum NativeAppSnapshotBindingChecks {
    typealias Backend = ControllerNativeAppSnapshotBackend
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ result: Bool) { cases.append(["name": name, "passed": result]); if !result { print("FAIL: " + name) } }
        let key = SettingsNativeAXElement(element: AXUIElementCreateSystemWide())
        let app = ControllerNativeElementContext.Node(element: key,
            snapshot: .init(supported: ["AXRole"], values: ["AXRole": .init(raw: "AXApplication" as NSString)], requested: nil))
        let window = ControllerNativeElementContext.Node(element: key,
            snapshot: .init(supported: ["AXRole"], values: ["AXRole": .init(raw: "AXWindow" as NSString)], requested: nil))
        let context = ControllerNativeElementContext(currentTransaction: { nil },
            lookup: { _ in .init(actualPID: getpid(), windowID: 11, bundleIdentifier: nil) }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No update freezing") },
            reenable: { _ in preconditionFailure("No update freezing") }, setLocation: { _, _ in preconditionFailure("No native event mutation") })
        let resources = ControllerNativeResources(context: context, lookup: { _ in nil }, windowServer: ws)
        let order = BindingOrdering()
        let environment = Backend.Owner.Environment(resolveIdentity: { _ in (.init(application: .current), getpid()) },
            makeApplicationNode: { _ in app }, makeOrdering: { _ in order },
            makeSignposter: { OSSignposter(subsystem: "local.cua.fixture", category: "readonly") },
            primaryWindow: { _ in nil }, children: { _ in [] }, role: { _ in "AXApplication" },
            windowID: { _ in 11 }, menuWindowID: { _ in 11 }, actualPID: { _ in getpid() }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { _ in preconditionFailure("No native attention") }, observeTermination: { _ in BindingLease() },
            terminatedPID: { _ in nil }, observeAX: { _, _, _ in BindingObservation() }, registerWeakOwner: { _ in },
            notificationCenter: NotificationCenter(), analytics: { _ in preconditionFailure("No activation analytics") },
            acquireAccessibility: { _ in preconditionFailure("No AX acquisition") }, releaseAccessibility: { _ in preconditionFailure("No AX assertion") },
            makeFocusEnforcer: { _ in preconditionFailure("No focus construction") }, deactivateFocusEnforcer: { _ in preconditionFailure("No focus operation") },
            setFocusEnforcerPID: { _, _ in preconditionFailure("No menu suppression") }, clearFocusEnforcerPID: { _ in preconditionFailure("No menu suppression") },
            scheduleOnMainActor: { _ in preconditionFailure("No cleanup scheduler in inactive fixture") }, orderOutCursor: { _ in preconditionFailure("No cursor hide") },
            now: { Date() }, sleep: { _ in preconditionFailure("No registry readiness wait") })
        let owner = try Backend.Owner(target: .init(bundleIdentifier: "local.cua.binding.fixture", url: URL(fileURLWithPath: "/private/tmp/binding-fixture.app")),
            chatID: nil, mcpRuntime: 2, isAXTreeDiffingEnabled: true, environment: environment)
        let backend = Backend(owner: owner, resources: resources)
        check("native capture backend retains actual typed owner and resources", backend.owner === owner && backend.resources === resources)
        check("capture binding setup leaves owner inactive", !owner.isActive && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil)
        let rawNode = EventStreamAXNode(key.element, supportedAttributes: [], attributes: [:])
        var transformed = EventStreamTransformedNode(element: rawNode)
        transformed.role = "AXButton"; transformed.title = " Add to List "
        let tree = EventStreamCollectedTree(roots: [EventStreamCollectedItem(node: transformed, path: [0], children: [], childrenSubset: nil)])
        let identity = EventStreamSnapshotAXIdentity(element: key.element)
        let revision = try EventStreamNativeTreeRevision.Revision.root(tree, lineageID: UUID().uuidString.lowercased(),
            identity: { EventStreamSnapshotAXIdentity(element: $0.element) }, render: { _ in
                .init(isFocusTree: false, roots: [.init(identity: identity, text: "Button: Add to List", sourcePath: [0])])
            })
        let nativeWindow = EventStreamNativeWindow(id: 11, processIdentifier: getpid(), frame: CGRect(x: 10, y: 20, width: 1000, height: 600),
            level: 0, title: "Fixture", ownerName: "Owned fixture")
        let source = ControllerNativeAppSnapshotSource(context: .init(application: rawNode, window: rawNode, focusedElement: nil, nativeWindow: nativeWindow), window: window)
        let selection = ControllerNativeAppSnapshotSelection(.init(applicationWindow: .init(application: rawNode, window: rawNode, nativeWindow: nativeWindow),
            windowRevision: revision, invalidationMonitor: nil, url: nil, contextType: .fullUIContext, screenshotNeededForContext: true), source: source)
        let capturedTree = try backend.makeTree(selection, diffingEnabled: true)
        check("native refetchable handle retains same selection", capturedTree.selection === selection && capturedTree.isAXTreeDiffingEnabled)
        check("Button search resolves native captured button IDs", capturedTree.findButton(labels: ["Add to List"]) == revision.renderTree.roots[0].elementID)
        check("Button search excludes unmatching label", capturedTree.findButton(labels: ["Other"]) == nil)
        let plain = try backend.makeAttachment(selection, image: nil, classifierEnabled: false)
        check("native tree-only attachment has no screenshot context flag", plain.screenshot == nil && plain.mimeType == nil && !plain.screenshotNeededForContext)
        check("native attachment uses actual rendered revision text", plain.text.contains("Button: Add to List"))
        check("native attachment includes actual inspector payload", plain.accessibilityInspectorPayload?.current.subjectID == revision.lineageID)
        let file = ControllerTemporaryImage(adopting: URL(fileURLWithPath: "/private/tmp/native-binding-image-no-disk-access.png"), cleanup: { _ in }, failed: { _ in })
        let image = ControllerNativeAppSnapshotImage(file: file, size: .init(width: 222, height: 111),
            geometry: .init(windowID: 11, ownerPID: getpid(), screenFrame: nativeWindow.frame, pixelWidth: 222, pixelHeight: 111), mimeType: "image/png")
        let withImage = try backend.makeAttachment(selection, image: image, classifierEnabled: false)
        let classified = try backend.makeAttachment(selection, image: image, classifierEnabled: true)
        check("native attachment retains actual temporary file and MIME", withImage.screenshot === file && withImage.mimeType == "image/png")
        check("native screenshot context flag follows selection when classifier disabled", withImage.screenshotNeededForContext)
        check("classifier clears context flag and preserves screenshot", !classified.screenshotNeededForContext && classified.screenshot === file)
        backend.retainImage(image)
        check("native owner retains same temporary image reference", owner.appSnapshotImageFiles.count == 1 && owner.appSnapshotImageFiles.first === file)
        backend.publishTree(capturedTree)
        check("native publication updates actual owner tree", owner.lastAXTree === capturedTree)
        check("native previous revision reads published selection revision", backend.previousRevision()?.value === revision)
        backend.publishWindow(selection)
        check("native last-window tuple retains captured context wrapper", owner.lastWindow?.0 == 11 && owner.lastWindow?.1.element == window.element && owner.lastWindow?.1.snapshot.values["AXRole"]?.raw as? String == "AXWindow")
        check("native image metadata uses decoded raster size", backend.imageSize(image) == .init(width: 222, height: 111))
        owner.currentlyFocusedMenuBarItem = window
        check("native menu root reads actual owner state", backend.focusedMenuBarItem?.element == window.element)
        owner.currentlyFocusedMenuBarItem = nil
        let center = owner.environment.notificationCenter
        let sink = BindingNotificationSink()
        let token = center.addObserver(forName: .init("computerUseAppControllerDidUpdateAppSnapshot"), object: nil, queue: nil) { notification in
            sink.record(notification.object as AnyObject?)
        }
        backend.notifyDidUpdate(); center.removeObserver(token)
        check("native update notification identifies complete owner", sink.last === owner)
        let sampling = (UserDefaults.standard.object(forKey: "feature/appSnapshotClassifier") as? Bool) ?? true
        check("native classifier reader preserves configured Bool and true default", backend.classifierEnabled == sampling)
        owner.scalingFactor = 123; owner.scaledScreenSize = .init(width: 7, height: 8)
        let noImage = try backend.plan(source, root: nil, skipScreenshot: true)
        check("native skip-screenshot plan leaves coordinate state unchanged", noImage.sizing == nil && owner.scalingFactor == 123 && owner.scaledScreenSize == .init(width: 7, height: 8))
        let menuPlan = try backend.plan(source, root: window, skipScreenshot: false)
        check("native menu plan omits screenshot sizing without coordinate mutation", menuPlan.sizing == nil && owner.scalingFactor == 123)
        let full = try backend.plan(source, root: nil, skipScreenshot: false)
        check("native screenshot plan updates actual owner coordinate state", full.sizing?.pointScale == owner.scalingFactor && full.sizing?.requestedSize == owner.scaledScreenSize && owner.scalingFactor != 123)
        let cursor = ControllerApprovedCursor()
        owner.virtualCursor = cursor
        check("approved cursor read-only accessor does not create a window", cursor.visibleWindowID == nil && backend.visibleCursorWindowID() == nil)
        owner.virtualCursor = nil; owner.appSnapshotImageFiles = []
        check("read-only native bindings leave focus and assertions absent", !owner.isActive && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil)
        let weakOwner = WeakBindingOwner()
        try autoreleasepool {
            var transient: Backend.Owner? = try .init(target: .init(bundleIdentifier: "local.cua.retention.fixture", url: URL(fileURLWithPath: "/private/tmp/retention-fixture.app")),
                chatID: nil, mcpRuntime: 2, isAXTreeDiffingEnabled: true, environment: environment)
            var reader: Backend? = .init(owner: transient!, resources: resources)
            let node = reader!.snapshotNode(window)
            let retainedSource = ControllerNativeAppSnapshotSource(context: .init(application: node, window: node, focusedElement: nil, nativeWindow: nativeWindow), window: window)
            let retainedSelection = ControllerNativeAppSnapshotSelection(.init(applicationWindow: .init(application: node, window: node, nativeWindow: nativeWindow),
                windowRevision: revision, invalidationMonitor: nil, url: nil, contextType: .fullUIContext, screenshotNeededForContext: false), source: retainedSource)
            transient!.lastAXTree = try reader!.makeTree(retainedSelection, diffingEnabled: true)
            weakOwner.value = transient
            reader = nil; transient = nil
        }
        check("published native snapshot closures release their complete owner", weakOwner.value == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "actual_native_data_adapters_executed": true, "owner_effect_environment_mocked": true,
            "native_AX_capture_focus_input_attention_cursor_window_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native appSnapshot bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
@MainActor private final class WeakBindingOwner { weak var value: ControllerNativeAppSnapshotBackend.Owner? }
private final class BindingNotificationSink: @unchecked Sendable {
    private let lock = NSLock(); private var stored: AnyObject?
    func record(_ value: AnyObject?) { lock.withLock { stored = value } }
    var last: AnyObject? { lock.withLock { stored } }
}
