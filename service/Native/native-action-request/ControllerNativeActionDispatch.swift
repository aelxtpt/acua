import Foundation
import CoreGraphics

@MainActor struct ControllerNativePageScrollBackend: ControllerPageScrollBackend {
    let controller: ControllerNativeAppController
    var visibleSize: CGSize { controller.owner.visibleRect.size }
    var visibleOrigin: CGPoint { controller.owner.visibleRect.origin }
    var scalingFactor: Double { controller.owner.scalingFactor }
    func move(to position: ControllerScaledCursorPosition) async throws {
        let backend = ControllerNativeCoordinateClickBackend(controller: controller)
        backend.position = position
        let target = try backend.target(at: backend.global(backend.position))
        try backend.requireAllowed(target)
        let windowID = try backend.cursorWindowID(target)
        // Check target policy and the selected protocol windowID before
        // creating the cursor; position is reread after cursor placement.
        await controller.createVirtualCursorIfNeeded().move(to: backend.global(backend.position),
            aboveWindowID: windowID, relativeToWindow: true, timing: .finished, animated: true)
        if !backend.isMenu(target) {
            try await backend.movePhysical(at: backend.global(backend.position), target: target)
        }
    }
    func prepare(_ id: Int) async throws -> ControllerNativeResolvedElement {
        try await controller.prepareToInteract(id: id, timing: .finished, positionElement: true, animated: true).element
    }
    func frame(_ element: ControllerNativeResolvedElement) -> CGRect? {
        controller.resources.geometry.frame(ControllerNativeAppSnapshotContext.contextual(element.node.element))
    }
    func clickablePoint(_ element: ControllerNativeResolvedElement) async throws -> CGPoint? {
        try await ControllerNativePositionBackend(controller: controller).clickablePoint(element).point
    }
    func scroll(deltaX: Int, deltaY: Int) async throws { try await controller.scroll(deltaX: deltaX, deltaY: deltaY) }
    func capture() async throws -> ControllerNativeAppController.AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: nil, disableAXDiffing: false, skipScreenshot: false)
    }
    func markNeedsSettle() { controller.owner.needsUISettleBeforeAppSnapshot = true }
}

@MainActor struct ControllerNativeActionDispatchBackend: ControllerActionDispatchBackend {
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    func coordinateClick(_ options: ControllerCoordinateClickParameters) async throws -> AppSnapshot? {
        try await controller.coordinateClick(options)
    }
    func elementClick(_ options: ControllerClickParameters) async throws -> AppSnapshot? {
        try await controller.click(options, runtime: .native(resources: controller.resources))
    }
    func secondary(elementID: Int, action: String, returnAppSnapshot: Bool) async throws -> AppSnapshot? {
        try await controller.performSecondaryAction(elementID: elementID, action: action, returnAppSnapshot: returnAppSnapshot)
    }
    func setValue(_ options: ControllerSetValueParameters) async throws -> AppSnapshot? {
        try await controller.setValue(options, runtime: .native(resources: controller.resources))
    }
    func selectText(_ options: ControllerTextSelectionParameters) async throws -> AppSnapshot? {
        try await controller.selectText(options)
    }
    func scroll(at target: XPCAppUsageBody.Target, direction: XPCAppUsageBody.ComputerUseIPCScrollDirection,
                pages: Double, returnAppSnapshot: Bool) async throws -> AppSnapshot? {
        try await ControllerPageScroll(backend: ControllerNativePageScrollBackend(controller: controller))
            .perform(at: target, direction: direction, pages: pages, returnAppSnapshot: returnAppSnapshot)
    }
    func keyboard(_ options: ControllerKeyboardActionParameters) async throws -> AppSnapshot? {
        try await controller.performKeyboardAction(options)
    }
    func paste(_ options: ControllerPasteParameters) async throws -> AppSnapshot? { try await controller.performPaste(options) }
}
