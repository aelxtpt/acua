import AppKit
import ApplicationServices
import Foundation
import os

@MainActor struct ControllerNativeRefetchIO {
    typealias Node = EventStreamTransformedNode<EventStreamAXNode>
    let roleStatus: @MainActor (Node) -> Int32
    let fresh: @MainActor (Node) -> Node
    let capture: @MainActor (ControllerNativeAppSnapshotSelection, Bool) throws -> ControllerNativeAppSnapshotSelection

    static func native(resources: ControllerNativeResources) -> Self {
        .init(roleStatus: { node in
            let key = SettingsNativeAXElement(element: node.element.element)
            if let bridge = resources.io.lookup(key) {
                do { _ = try bridge.read("AXRole"); return 0 }
                catch let error as ControllerNativeElementDecoding.Failure {
                    if case .accessibility(let status) = error { return status }
                    return AXError.failure.rawValue
                } catch { return AXError.failure.rawValue }
            }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(key.element, "AXRole" as CFString, &value).rawValue
        }, fresh: { node in
            EventStreamNativeNode.construct(EventStreamNativeSnapshots().node(node.element.element))
        }, capture: { previous, diff in
            let application = ControllerNativeAppSnapshotContext.contextual(previous.value.applicationWindow.application)
            let pid = try ControllerAXEnablementNative.pid(application.element, lookup: { resources.io.lookup($0)?.ordinaryPID })
            let source = try ControllerNativeAppSnapshotContext.focused(application: application, pid: pid, resources: resources)
            let snapshots = EventStreamNativeSnapshots()
            let backend = EventStreamNativeSelectionExtractorBackend<ControllerAXEnablementAssertion>(enableAccessibility: { app, window, type in
                resources.enablement.acquire(application: ControllerNativeAppSnapshotContext.contextual(app),
                    window: ControllerNativeAppSnapshotContext.contextual(window), context: type.rawValue)
            }, disable: { $0.disable() }, snapshots: snapshots, source: .init(snapshots: snapshots))
            // The synchronous recapture has fresh focus, no old menu
            // root or cache, old revision lineage and actual AX enablement.
            let value = try EventStreamNativeSelectionExtractor.extract(from: source.context, type: .fullUIContext,
                cache: nil, previous: previous.value.windowRevision, rootOverride: nil,
                performAccessibilityEnablement: true, enableAXDiffing: diff, backend: backend)
            return .init(value, source: source)
        })
    }
}

@MainActor final class ControllerNativeResolvedElement {
    typealias Node = ControllerNativeRefetchIO.Node
    private(set) var node: Node
    let containingTree: ControllerRefetchableAppSnapshotTree
    private let resources: ControllerNativeResources
    private let io: ControllerNativeRefetchIO
    init(node: Node, tree: ControllerRefetchableAppSnapshotTree, resources: ControllerNativeResources, io: ControllerNativeRefetchIO) {
        self.node = node; containingTree = tree; self.resources = resources; self.io = io
    }
    func refetchIfNeeded(validateElement: Bool, ignoreValueChange: Bool) throws {
        let resolved = try ControllerElementRefetch(backend: ControllerNativeElementRefetch(tree: containingTree, resources: resources, io: io))
            .resolve(node, validateElement: validateElement, ignoreValueChange: ignoreValueChange)
        node = resolved.node
    }
    /// The write runs first. On success only, refresh/validate while admitting
    /// its value change; neither a failed write nor failed refresh replaces node.
    func afterWriting(_ write: (Node) throws -> Void) throws {
        try write(node)
        try refetchIfNeeded(validateElement: true, ignoreValueChange: true)
    }
}

@MainActor struct ControllerNativeElementRefetch: ControllerElementRefetchBackend {
    typealias Element = ControllerNativeRefetchIO.Node
    typealias Key = EventStreamSnapshotAXIdentity
    typealias Handle = ControllerNativeResolvedElement
    let tree: ControllerRefetchableAppSnapshotTree
    let resources: ControllerNativeResources
    let io: ControllerNativeRefetchIO
    init(tree: ControllerRefetchableAppSnapshotTree, resources: ControllerNativeResources, io: ControllerNativeRefetchIO? = nil) {
        self.tree = tree; self.resources = resources; self.io = io ?? .native(resources: resources)
    }
    func item(for id: Int) -> Element? { tree.selection.value.windowRevision.item(for: id)?.node }
    func monitorSnapshot() -> ControllerElementInvalidation<Key>? {
        guard let monitor = tree.selection.value.invalidationMonitor else { return nil }
        let snapshot = monitor.state
        // Read the state tuple, without requiresRefetch's extra
        // hasObserver policy or a second read after the role probe.
        return .init(layoutChanged: snapshot.layoutChanged, destroyed: snapshot.destroyedElements)
    }
    func identity(_ element: Element) -> Key { .init(element: element.element.element) }
    func roleStatus(_ element: Element) -> Int32 { io.roleStatus(element) }
    func fresh(_ element: Element) -> Element { io.fresh(element) }
    func matches(_ expected: Element, _ candidate: Element, ignoreValueChange: Bool) -> Bool {
        EventStreamElementValidation.matches(expected, candidate, ignoreValueChange: ignoreValueChange)
    }
    func elements() -> [Element] { tree.selection.value.windowRevision.tree.preorder.map(\.node) }
    func refetchTree() throws {
        let value = try io.capture(tree.selection, tree.isAXTreeDiffingEnabled)
        tree.selection = value
    }
    func box(_ element: Element) -> Handle { .init(node: element, tree: tree, resources: resources, io: io) }
    func log(_ message: ControllerElementRefetchLog) {
        Logger(subsystem: "local.cua", category: "RefetchableAppSnapshotAXTree").info("log[\(message.rawValue, privacy: .public)]")
    }
}

extension ControllerNativeAppController {
    func resolveElement(_ id: Int, in tree: ControllerRefetchableAppSnapshotTree, validateElement: Bool = true) throws -> ControllerNativeResolvedElement {
        try ControllerElementRefetch(backend: ControllerNativeElementRefetch(tree: tree, resources: resources))
            .resolve(id: id, validateElement: validateElement)
    }
    /// The positioning provider must implement native reveal/point/motion.
    /// It is required explicitly until the native path is fully composed.
    func prepareToInteract(id: Int, timing: CursorInteractionTiming?, positionElement: Bool, animated: Bool,
        position: @escaping @MainActor (ControllerNativeResolvedElement, CursorInteractionTiming?, ControllerRefetchableAppSnapshotTree, Bool) async throws -> Bool)
        async throws -> ControllerInteractionPreparation<ControllerNativePreparationBackend>.Result {
        try await ControllerInteractionPreparation(backend: ControllerNativePreparationBackend(controller: self, positionElement: position))
            .prepare(id: id, timing: timing, positionElement: positionElement, animated: animated)
    }
}

@MainActor struct ControllerNativePreparationBackend: ControllerInteractionPreparationBackend {
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Element = ControllerNativeResolvedElement
    typealias Timing = CursorInteractionTiming
    let controller: ControllerNativeAppController
    let positionElement: @MainActor (Element, Timing?, Tree, Bool) async throws -> Bool
    var lastTree: Tree? { controller.owner.lastAXTree }
    func resolve(_ id: Int, in tree: Tree) throws -> Element { try controller.resolveElement(id, in: tree, validateElement: true) }
    func ensureFocusEnforcer() { _ = controller.owner.activateFocusEnforcer() }
    func position(_ element: Element, timing: Timing?, tree: Tree, animated: Bool) async throws -> Bool {
        try await positionElement(element, timing, tree, animated)
    }
    func actualPID(_ element: Element) throws -> Int32 { try controller.resources.context.identity.actualPID(.init(element: element.node.element.element)) }
    func requireAllowed(_ pid: Int32) throws { try NativeInteractionTargetPolicy.requireAllowed(processIdentifier: pid) }
}
