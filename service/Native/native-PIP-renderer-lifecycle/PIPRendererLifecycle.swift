import Foundation

/// Shared by the concrete renderer and controlled checks. Generations use
/// checked signed increments, so an overflow traps.
@MainActor final class PIPRendererLifecycle {
    private(set) var geometryGeneration: Int
    private(set) var captureGeneration: Int
    private(set) var cursorGeneration: Int
    private(set) var sourceUnavailable = false
    private(set) var frameDeliverySuspended = false

    init(geometry: Int = 0, capture: Int = 0, cursor: Int = 0) {
        geometryGeneration = geometry; captureGeneration = capture; cursorGeneration = cursor
    }
    @discardableResult func beginGeometryUpdate() -> Int { geometryGeneration += 1; return geometryGeneration }
    @discardableResult func beginCapture() -> Int { captureGeneration += 1; return captureGeneration }
    @discardableResult func beginCursorCapture() -> Int { cursorGeneration += 1; return cursorGeneration }
    func geometryIsCurrent(_ generation: Int) -> Bool { generation == geometryGeneration }
    func captureIsCurrent(_ generation: Int) -> Bool { generation == captureGeneration }
    func cursorIsCurrent(_ generation: Int) -> Bool { generation == cursorGeneration }
    func suspendDelivery(flush: () -> Void) {
        guard !frameDeliverySuspended else { return }
        frameDeliverySuspended = true
        flush()
    }
    func resumeDelivery() { frameDeliverySuspended = false }
    func invalidateGenerations() {
        geometryGeneration += 1
        captureGeneration += 1
        cursorGeneration += 1
    }

    /// One-shot latch; keep the main capture/key/target bounds intact.
    /// Only cursor capture is detached/stopped here. Full stop is separate.
    @discardableResult
    func markSourceUnavailable(cancelGeometry: () -> Void, flushDisplay: () -> Void,
                               hideCursor: () -> Void, detachCursor: () -> Void,
                               resolvePresentation: () -> Void, notify: () -> Void) -> Bool {
        guard !sourceUnavailable else { return false }
        sourceUnavailable = true
        cancelGeometry()
        invalidateGenerations()
        suspendDelivery(flush: flushDisplay)
        hideCursor()
        detachCursor()
        resolvePresentation()
        notify()
        return true
    }
}
