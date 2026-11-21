import AppKit
import Foundation

private func controllerPointOnMain<T: Sendable>(_ body: @MainActor @Sendable () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
}
@MainActor struct ControllerNativePositionBackend: ControllerElementPositionBackend {
    typealias Element = ControllerNativeResolvedElement
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Cursor = ControllerApprovedCursor
    typealias Timing = CursorInteractionTiming
    let controller: ControllerNativeAppController
    var beforeMove: (@MainActor (Cursor, CGPoint, UInt32, Bool) async -> Void)? = nil
    func clickablePoint(_ element: Element) async throws -> ControllerPointResult {
        let resources = controller.resources
        var backend = ControllerNativeClickablePoint(geometry: resources.geometry)
        backend.leafKey = .init(element: element.node.element.element)
        backend.currentLeaf = {
            controllerPointOnMain { ControllerNativeAppSnapshotContext.contextual(element.node.element) }
        }
        backend.setLeafReveal = {
            try controllerPointOnMain {
                try element.afterWriting { node in
                    try resources.io.setBoolean("AXScrollToVisible", true, on: .init(element: node.element.element), context: resources.context)
                }
            }
        }
        backend.setLeafValue = { value, attribute in
            try controllerPointOnMain {
                try element.afterWriting { node in
                    try ControllerNativeClickablePoint(geometry: resources.geometry).write(value, attribute: attribute,
                        node: ControllerNativeAppSnapshotContext.contextual(node.element))
                }
            }
        }
        let initial = ControllerNativeAppSnapshotContext.contextual(element.node.element)
        return try await ControllerClickablePoint(backend: backend).point(initial, scrollToVisible: true)
    }
    var cursorEnabled: Bool { ComputerUseFeaturePreferences.cursorEnabled }
    func ensureCursor() -> Cursor {
        controller.createVirtualCursorIfNeeded()
    }
    func windowID(_ tree: Tree) -> UInt32 { tree.selection.value.applicationWindow.nativeWindow.id }
    func delegateMove(_ cursor: Cursor, point: CGPoint, windowID: UInt32, animated: Bool) async { await beforeMove?(cursor, point, windowID, animated) }
    func move(_ cursor: Cursor, point: CGPoint, windowID: UInt32, timing: Timing, animated: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            cursor.place(at: point, active: true, animated: animated, targetWindowID: windowID, timing: timing) { continuation.resume(returning: $0) }
        }
    }
    func notifyMoved(_ cursor: Cursor) {
        NotificationCenter.default.post(name: .init("computerUseCursorDidFinishMove"), object: cursor)
    }
}
extension ControllerNativeAppController {
    func positionElement(_ element: ControllerNativeResolvedElement, timing: CursorInteractionTiming?, tree: ControllerRefetchableAppSnapshotTree,
        animated: Bool, beforeMove: (@MainActor (ControllerApprovedCursor, CGPoint, UInt32, Bool) async -> Void)? = nil) async throws -> Bool {
        try await ControllerElementPosition(backend: ControllerNativePositionBackend(controller: self, beforeMove: beforeMove))
            .position(element, timing: timing, tree: tree, animated: animated)
    }
    func prepareToInteract(id: Int, timing: CursorInteractionTiming?, positionElement: Bool, animated: Bool) async throws -> ControllerInteractionPreparation<ControllerNativePreparationBackend>.Result {
        try await prepareToInteract(id: id, timing: timing, positionElement: positionElement, animated: animated,
            position: { element, timing, tree, animated in try await self.positionElement(element, timing: timing, tree: tree, animated: animated) })
    }
}
