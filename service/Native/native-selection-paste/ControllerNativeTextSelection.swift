import ApplicationServices
import Foundation

private func controllerSelectionOnMain<T: Sendable>(_ body: @MainActor @Sendable () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
}
protocol ControllerNativeParameterizedValueBridge: ControllerNativeElementBridge {
    func parameterizedValue(_ attribute: String, parameter: ControllerNativeAXValue) throws -> ControllerNativeAXValue?
}
enum ControllerNativeSelectionIOFailure: Error { case unsupportedHostedParameterizedValue }

@MainActor struct ControllerNativeSelectionIO {
    let resources: ControllerNativeResources
    func parameter(_ range: NSRange) throws -> ControllerNativeAXValue {
        var range = CFRange(location: range.location == NSNotFound ? kCFNotFound : range.location, length: range.length)
        guard let raw = AXValueCreate(.cfRange, &range) else { throw ControllerNativeElementDecoding.Failure.typeMismatch }
        return .init(raw: raw)
    }
    func bounds(_ range: NSRange, element: ControllerNativeResolvedElement) throws -> CGRect? {
        let parameter = try parameter(range), key = SettingsNativeAXElement(element: element.node.element.element)
        let result: ControllerNativeAXValue?
        if let provider = resources.io.lookup(key) {
            guard let provider = provider as? any ControllerNativeParameterizedValueBridge else {
                throw ControllerNativeSelectionIOFailure.unsupportedHostedParameterizedValue
            }
            result = try provider.parameterizedValue("AXBoundsForRange", parameter: parameter)
        } else {
            var raw: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(key.element, "AXBoundsForRange" as CFString, parameter.raw, &raw)
            guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
            result = raw.map { .init(raw: $0) }
        }
        guard let result else { return nil }
        return try ControllerNativeGeometryDecoding.decode(result, as: CGRect.self, strict: true)
    }
    func write(_ range: NSRange, element: ControllerNativeResolvedElement) throws {
        let value = try parameter(range)
        try element.afterWriting { node in
            try ControllerNativeClickablePoint(geometry: resources.geometry).write(value, attribute: "AXSelectedTextRange",
                node: ControllerNativeAppSnapshotContext.contextual(node.element), refreshLeaf: false)
        }
    }
    func reveal(_ element: ControllerNativeResolvedElement, frame: CGRect) async throws -> Bool {
        //Reuse C100's native reveal plan while preserving the refetchable
        //wrapper's post-write policy for writes on the selected leaf itself.
        let resources = resources
        var backend = ControllerNativeClickablePoint(geometry: resources.geometry)
        backend.leafKey = .init(element: element.node.element.element)
        backend.currentLeaf = {
            controllerSelectionOnMain { ControllerNativeAppSnapshotContext.contextual(element.node.element) }
        }
        backend.setLeafReveal = {
            try controllerSelectionOnMain {
                try element.afterWriting { node in
                    try resources.io.setBoolean("AXScrollToVisible", true, on: .init(element: node.element.element), context: resources.context)
                }
            }
        }
        backend.setLeafValue = { value, attribute in
            try controllerSelectionOnMain {
                try element.afterWriting { node in
                    try ControllerNativeClickablePoint(geometry: resources.geometry).write(value, attribute: attribute,
                        node: ControllerNativeAppSnapshotContext.contextual(node.element), refreshLeaf: false)
                }
            }
        }
        let initial = ControllerNativeAppSnapshotContext.contextual(element.node.element)
        return try await Self.revealPlan(backend, node: initial, frame: frame)
    }
    nonisolated private static func revealPlan(_ backend: ControllerNativeClickablePoint,
        node: ControllerNativeElementContext.Node, frame: CGRect) async throws -> Bool {
        try ControllerClickablePoint(backend: backend).reveal(node, target: frame)
    }
}

@MainActor struct ControllerNativeTextSelectionRuntime {
    let bounds: @MainActor (NSRange, ControllerNativeResolvedElement) throws -> CGRect?
    let reveal: @MainActor (ControllerNativeResolvedElement, CGRect) async throws -> Bool
    let move: @MainActor (ControllerApprovedCursor, CGPoint, UInt32) async -> Void
    let settle: @MainActor (ControllerNativeElementContext.Node) async throws -> ControllerNativeAppSnapshotCache?
    static func native(resources: ControllerNativeResources) -> Self {
        let io = ControllerNativeSelectionIO(resources: resources), settling = ControllerNativeClickRuntime.native(resources: resources)
        return .init(bounds: { try io.bounds($0, element: $1) }, reveal: { try await io.reveal($0, frame: $1) },
            move: { await $0.move(to: $1, aboveWindowID: $2, relativeToWindow: true, timing: .closeEnough, animated: true) },
            settle: { try await settling.settle($0, nil, 0.25, false) })
    }
}

@MainActor struct ControllerNativeTextSelectionBackend: ControllerTextSelectionBackend {
    typealias Element = ControllerNativeResolvedElement
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Cursor = ControllerApprovedCursor
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let runtime: ControllerNativeTextSelectionRuntime
    func prepare(_ id: Int) async throws -> (element: Element, tree: Tree) {
        let value = try await controller.prepareToInteract(id: id, timing: nil, positionElement: false, animated: true)
        return (value.element, value.tree)
    }
    func selectionSettable(_ element: Element) -> Bool {
        ControllerNativeClickablePoint(geometry: controller.resources.geometry)
            .supportedAndSettable("AXSelectedTextRange", ControllerNativeAppSnapshotContext.contextual(element.node.element))
    }
    func sourceRange(in tree: Tree, parameters: ControllerTextSelectionParameters) -> NSRange? {
        guard let node = tree.selection.value.windowRevision.item(for: parameters.elementID)?.node else { return nil }
        return Self.sourceRange(node, parameters: parameters)
    }
    static func sourceRange(_ node: ControllerNativeRefetchIO.Node, parameters: ControllerTextSelectionParameters) -> NSRange? {
        let source = ControllerSelectionSource(displayedRichText: node.transformedString?.description,
            sourceOffsets: node.transformedString?.sourceOffsets, attributedText: node.attributedString?.string,
            stringValue: node.stringValue, truncationOffset: node.truncationRange?.location ?? 0)
        return ControllerSelectionSourceRange.resolve(source, text: parameters.text, prefix: parameters.prefix, suffix: parameters.suffix)
    }
    var cursorEnabled: Bool { ComputerUseFeaturePreferences.cursorEnabled }
    func bounds(for range: NSRange, element: Element) throws -> CGRect? { try runtime.bounds(range, element) }
    func reveal(_ element: Element, frame: CGRect) async throws -> Bool { try await runtime.reveal(element, frame) }
    func windowFrame(_ tree: Tree) -> CGRect { tree.selection.value.applicationWindow.nativeWindow.frame }
    func ensureCursor() -> Cursor { controller.createVirtualCursorIfNeeded() }
    func windowID(_ tree: Tree) -> UInt32 { tree.selection.value.applicationWindow.nativeWindow.id }
    func move(_ cursor: Cursor, point: CGPoint, windowID: UInt32) async { await runtime.move(cursor, point, windowID) }
    func focus(_ element: Element, tree: Tree) async throws {
        let selection = tree.selection.value.applicationWindow
        let captured = ControllerNativeClickContext(application: ControllerNativeAppSnapshotContext.contextual(selection.application),
            window: ControllerNativeAppSnapshotContext.contextual(selection.window), focus: controller.owner.focusEnforcer)
        try await ControllerFieldFocus(backend: ControllerNativeFieldFocus(resolved: element, captured: captured, resources: controller.resources)).focusFieldIfNeeded()
    }
    func write(_ range: NSRange, element: Element) throws { try ControllerNativeSelectionIO(resources: controller.resources).write(range, element: element) }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle() async throws -> Cache? { try await runtime.settle(controller.owner.app) }
    func capture(cache: Cache?) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: false, skipScreenshot: false)
    }
}
extension ControllerNativeAppController {
    func selectText(_ parameters: ControllerTextSelectionParameters,
                    runtime: ControllerNativeTextSelectionRuntime? = nil) async throws -> AppSnapshot? {
        try await ControllerTextSelection(backend: ControllerNativeTextSelectionBackend(controller: self,
            runtime: runtime ?? .native(resources: resources))).select(parameters)
    }
}
