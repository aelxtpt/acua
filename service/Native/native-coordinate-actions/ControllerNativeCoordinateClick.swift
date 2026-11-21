import AppKit
import ApplicationServices

@MainActor struct ControllerNativeCoordinateSelection {
    let entry: ControllerAXWindowRegistry<ControllerNativeElementContext.Node>.Entry
    let delivery: ControllerMouseEventTarget<ControllerNativeElementContext.Node>
}

@MainActor struct ControllerNativeCoordinateClickBackend: ControllerCoordinateClickBackend {
    typealias Node = ControllerNativeElementContext.Node
    typealias Target = ControllerNativeCoordinateSelection
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    var resources: ControllerNativeResources { controller.resources }
    var position: ControllerScaledCursorPosition {
        get { controller.owner.scaledCursorPosition }
        nonmutating set { controller.owner.scaledCursorPosition = newValue }
    }
    func global(_ position: ControllerScaledCursorPosition) -> CGPoint {
        position.global(scale: controller.owner.scalingFactor, origin: controller.owner.visibleRect.origin)
    }
    func target(at point: CGPoint) throws -> Target {
        let registered = controller.owner.windows()
        let ordered = ControllerOrderedWindows.select(registered: registered,
            orderedIDs: ControllerNativeCoordinateTarget.orderedWindowIDs())
        guard !ordered.isEmpty else { throw ControllerCoordinateTargetFailure.noWindows }
        guard let entry = ordered.first(where: { resources.geometry.frame($0.node)?.contains(point) == true }) else {
            throw ControllerCoordinateTargetFailure.noWindowAtPoint(point)
        }
        let backend = ControllerNativeCoordinateTarget(resources: resources)
        let element = try backend.element(at: point, application: controller.owner.app)
        return .init(entry: entry, delivery: try backend.target(at: point,
            application: controller.owner.app, window: entry.node, element: element))
    }
    func requireAllowed(_ target: Target) throws {
        try NativeInteractionTargetPolicy.requireAllowed(processIdentifier: target.delivery.pid)
    }
    func cursorWindowID(_ target: Target) throws -> UInt32 {
        if target.entry.kind == .menu { return try controller.owner.environment.menuWindowID(target.entry.node) }
        return try controller.owner.environment.windowID(target.entry.node)
    }
    func prepareCursor(at point: CGPoint, above windowID: UInt32, drag: Bool, animated: Bool) async {
        let cursor = controller.createVirtualCursorIfNeeded()
        await cursor.move(to: point, aboveWindowID: windowID, relativeToWindow: true,
                          timing: drag ? .finished : .closeEnough, animated: animated)
    }
    func isMenu(_ target: Target) -> Bool { target.entry.kind == .menu }
    private var events: ControllerNativeCoordinateEvents {
        .init(setWindowLocation: { resources.windowServer.setLocation($0, $1) })
    }
    func movePhysical(at point: CGPoint, target: Target) async throws {
        let delivery = target.delivery
        let movement = try events.movement(at: point, windowID: delivery.windowID,
            bounds: delivery.windowBounds, flipped: delivery.windowUsesFlippedCoordinates)
        try await ControllerNativeKeyboardEvents.send(movement.map { .init(event: $0) },
                                                       to: delivery.pid, delay: .milliseconds(10))
    }
    func pressMenu(_ target: Target) throws {
        guard let element = target.delivery.element, resources.io.actions(element.element).contains("AXPress") else {
            throw ControllerCoordinateClickFailure.cannotPressMenuItem
        }
        try NativeElementAction.perform(element, action: "AXPress",
                                       backend: ControllerNativeGeometry.Backend(reader: resources.geometry))
    }
    private func parent(_ node: Node) -> Node? {
        ControllerGlobalFocusNative.element("AXParent", node, context: resources.context)
    }
    private func insideWebView(_ element: Node?) -> Bool {
        guard let element else { return false }
        return ControllerInsideWebView.test(element, role: resources.context.context.role, parent: parent)
    }
    private func maySelect(_ node: Node?) -> Bool {
        guard let node else { return false }
        return (try? NativeClickFocusPolicy.mayCauseSelection(node,
            role: { resources.context.context.role($0) }, selectable: { node in
                let role = resources.context.context.role(node)
                guard role != "AXMenuItem", role != "AXMenuBarItem" else { return false }
                return EventStreamAttributeAvailability.supports("AXSelected", supported: node.snapshot.supported,
                    requested: node.snapshot.requested, refresh: { resources.context.context.environment.supported(node.element) })
                    && resources.io.isSettable("AXSelected", on: node.element)
            }, supported: { node in
                node.snapshot.supported.isEmpty && node.snapshot.requested == nil
                    ? resources.context.context.environment.supported(node.element) : node.snapshot.supported
            }, parent: parent, checkpoint: {})) ?? false
    }
    func click(_ target: Target, destination: CGPoint?, options: ControllerCoordinateClickParameters,
               key: ControllerHeldClickKey) async throws {
        let resources = self.resources
        let delivery = target.delivery, web = insideWebView(target.delivery.element)
        let visible = controller.owner.virtualCursor?.visibleWindowID != nil
        let enabled = options.animateCursor ? ComputerUseFeaturePreferences.cursorEnabled : false
        let cursor = visible && enabled ? controller.owner.virtualCursor : nil
        let point = global(position)
        let window = controller.owner.lastWindow?.1
        let focus = controller.owner.focusEnforcer
        let application = controller.owner.app
        let focusFlags = try await ControllerClickFocusPreparation<Node>(focused: { focus?.state.believesFocused },
            actualActive: {
                let pid = try ControllerAXEnablementNative.pid(application.element,
                    lookup: { resources.io.lookup($0)?.ordinaryPID })
                return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
            }, catalyst: { resources.geometry.value("_AXExhibitsMacCatalystBehavior", on: application) ?? false },
            maySelect: maySelect, menuButton: { $0.map { resources.context.context.role($0) == "AXMenuButton" } ?? false },
            enforce: { try await focus?.safelyEnforceActiveState(for: window) })
            .prepare(accessibility: false, element: delivery.element, web: web,
                     held: key.keyCode != nil || key.eventFlags != 0)
        let mouse = try events.click(at: point, destination: destination, button: options.button, count: options.count,
            flags: key.eventFlags | focusFlags, windowID: delivery.windowID,
            bounds: delivery.windowBounds, flipped: delivery.windowUsesFlippedCoordinates)
        let held = try ControllerNativeClickEvents(windowServer: resources.windowServer).held(key)
        if let held { for event in held.down { ControllerNativeClickEvents.post(event, pid: delivery.pid) } }
        defer { if let held { for event in held.up { ControllerNativeClickEvents.post(event, pid: delivery.pid) } } }
        func sender(_ cursor: ControllerApprovedCursor?) -> ControllerCoordinateClickSender<CGEvent> {
            .init(isDown: { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) },
                post: { event in event.timestamp = DispatchTime.now().uptimeNanoseconds; event.postToPid(delivery.pid) },
                cursor: cursor.map { value in { value.setPressed($0) } }, wait: { try await Task.sleep(for: $0) })
        }
        let interval: Duration? = destination == nil ? .milliseconds(50) : nil
        if let cursor {
            try await Task { @MainActor in try await sender(cursor).send(mouse, hold: options.hold, interval: interval) }.value
        } else { try await sender(nil).send(mouse, hold: options.hold, interval: interval) }
    }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle() async throws -> Cache? {
        try await ControllerNativeClickRuntime.native(resources: resources).settle(controller.owner.app, nil, 0.25, false)
    }
    func capture(cache: Cache?) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: false, skipScreenshot: false)
    }
}
extension ControllerNativeAppController {
    func coordinateClick(_ options: ControllerCoordinateClickParameters) async throws -> AppSnapshot? {
        try await ControllerCoordinateClick(backend: ControllerNativeCoordinateClickBackend(controller: self)).click(options)
    }
}
