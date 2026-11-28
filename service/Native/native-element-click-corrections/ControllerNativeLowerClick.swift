import AppKit
import ApplicationServices
import Foundation

@MainActor struct ControllerNativeLowerClick: ControllerLowerClickBackend {
    typealias Node = ControllerNativeElementContext.Node
    typealias Event = ControllerFocusNativeEvent
    let resolved: ControllerNativeResolvedElement
    let captured: ControllerNativeClickContext
    let resources: ControllerNativeResources
    let cursor: ControllerApprovedCursor?
    var element: Node { ControllerNativeAppSnapshotContext.contextual(resolved.node.element) }
    var hasCursor: Bool { cursor != nil }
    func actions() -> [String] { resources.io.actions(element.element) }
    private func parent(_ node: Node) -> Node? { ControllerGlobalFocusNative.element("AXParent", node, context: resources.context) }
    func webShaped() -> Bool {
        ControllerInsideWebView.test(element, role: resources.context.context.role, parent: parent)
    }
    func clickablePoint() async throws -> CGPoint? {
        try await ControllerClickablePoint(backend: ControllerNativeClickablePoint(geometry: resources.geometry)).point(element, scrollToVisible: false).point
    }
    func requireInsideWindow() throws {
        guard resources.io.lookup(element.element) == nil else { return }
        if try AXClickableTarget.isOutsideWindow(element.element.element) {
            throw ServiceError(.unknownError, ClickableGeometry.offscreenClickMessage)
        }
    }
    func webHit() async -> Bool {
        do {
            guard let point = try await clickablePoint(), let hit = try hitTest(captured.application, point: point) else { return false }
            for ancestor in AXParentChain(start: hit, parent: parent) {
                if CFEqual(ancestor.element.element, element.element.element) { return true }
            }
        } catch {}
        return false
    }
    private func hitTest(_ root: Node, point: CGPoint) throws -> Node? {
        if let provider = resources.io.lookup(root.element) {
            guard let provider = provider as? any ControllerNativeMouseHitTestBridge else { throw ControllerNativeMouseHitTestFailure.unsupportedHostedHitTest }
            return try provider.element(at: point).map(resources.context.context.node)
        }
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(root.element.element, Float(point.x), Float(point.y), &hit)
        guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
        return hit.map { resources.context.context.node(.init(element: $0)) }
    }
    func target(at point: CGPoint) throws -> ControllerMouseEventTarget<Node> {
        try ControllerMouseEventTargeting(backend: ControllerNativeMouseEventTarget(resources: resources))
            .target(at: point, application: captured.application, window: captured.window, element: element)
    }
    private func maySelect(_ node: Node?) -> Bool {
        guard let node else { return false }
        return (try? NativeClickFocusPolicy.mayCauseSelection(node, role: { resources.context.context.role($0) },
            selectable: { node in
                let role = resources.context.context.role(node)
                guard role != "AXMenuItem", role != "AXMenuBarItem" else { return false }
                return EventStreamAttributeAvailability.supports("AXSelected", supported: node.snapshot.supported, requested: node.snapshot.requested,
                    refresh: { resources.context.context.environment.supported(node.element) }) && resources.io.isSettable("AXSelected", on: node.element)
            },
            supported: { key in
                // The protocol attribute tuple is the captured supported set;
                // refresh only when it is unknown, as in the shared reader.
                key.snapshot.supported.isEmpty && key.snapshot.requested == nil
                    ? resources.context.context.environment.supported(key.element) : key.snapshot.supported
            }, parent: parent, checkpoint: {})) ?? false
    }
    func prepareFocus(accessibility: Bool, element: Node?, web: Bool, held: Bool) async throws -> UInt64 {
        try await ControllerClickFocusPreparation<Node>(focused: { captured.focus?.state.believesFocused }, actualActive: {
            let pid = try ControllerAXEnablementNative.pid(captured.application.element, lookup: { resources.io.lookup($0)?.ordinaryPID })
            return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        }, catalyst: { resources.geometry.value("_AXExhibitsMacCatalystBehavior", on: captured.application) ?? false },
            maySelect: maySelect, menuButton: { $0.map { resources.context.context.role($0) == "AXMenuButton" } ?? false },
            enforce: { try await captured.focus?.safelyEnforceActiveState(for: captured.window) })
            .prepare(accessibility: accessibility, element: element, web: web, held: held)
    }
    func pressCursor() async throws {
        guard let cursor else { return }
        try await ControllerClickCursorPress(visible: { cursor.visibleWindowID != nil }, pressed: cursor.setPressed,
            wait: { try await Task.sleep(for: $0) }).press()
    }
    func perform(_ action: String) throws {
        // Uses the menu-aware protocol action executor. The refetchable
        // wrapper's post-write validation belongs to setValue, not this
        // action path.
        try NativeElementAction.perform(element, action: action, backend: ControllerNativeGeometry.Backend(reader: resources.geometry))
    }
    func mouseEvents(at point: CGPoint, target: ControllerMouseEventTarget<Node>, options: ControllerLowerClickOptions, flags: UInt64) throws -> [Event] {
        try ControllerNativeClickEvents(windowServer: resources.windowServer).mouse(at: point, target: target, options: options, flags: flags)
    }
    func heldEvents(_ key: ControllerHeldClickKey) async throws -> ControllerHeldEventPair<Event>? {
        try ControllerNativeClickEvents(windowServer: resources.windowServer).held(key)
    }
    func post(_ event: Event, pid: Int32) { ControllerNativeClickEvents.post(event, pid: pid) }
    func deliverMouse(_ events: [Event], pid: Int32, hold: Duration?) async throws {
        func sender(_ cursor: ControllerApprovedCursor?) -> ControllerClickEventSender<Event> {
            .init(isDown: { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.event.type) },
                post: { post($0, pid: pid) }, cursor: cursor.map { value in { value.setPressed($0) } },
                wait: { try await Task.sleep(for: $0) })
        }
        if let cursor {
            // An unstructured MainActor task runs the cursor sender. Parent cancellation does not cancel this task.
            try await Task { @MainActor in try await sender(cursor).send(events, hold: hold) }.value
        } else { try await sender(nil).send(events, hold: hold) }
    }
}

extension ControllerNativeClickRuntime {
    /// Concrete click provider; settling stays an explicit parameter rather
    /// than being composed from the native cache/notification contract.
    static func nativeClick(resources: ControllerNativeResources,
        settle: @escaping @MainActor (ControllerNativeElementContext.Node, Double?, Double, Bool) async throws -> ControllerNativeAppSnapshotCache?) -> Self {
        .init(click: { element, captured, delivery, cursor in
            let backend = ControllerNativeLowerClick(resolved: element, captured: captured, resources: resources, cursor: cursor)
            try await ControllerLowerClick(backend: backend).click(.init(button: delivery.button == .left ? 0 : 1, count: delivery.count,
                hold: delivery.hold, key: delivery.key, alwaysSimulate: delivery.alwaysSimulate))
        }, settle: settle)
    }
}
