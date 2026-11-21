import Foundation

/// The independent app/menu and movement reasons use tuple semantics
/// rather than treating the cursor as permanently above everything.
@MainActor final class ControllerCursorWindowOrdering {
    struct Environment {
        let number: () -> Int
        let visibleNumbers: () -> [Int]?
        let targetLevel: (UInt32) -> Int?
        let setServerOverlayLevel: (UInt32) -> Void
        let setLevel: (Int) -> Void
        let front: () -> Void
        let above: (UInt32) -> Void
        let isVisible: () -> Bool
        let orderOut: () -> Void
        let stopMotion: () -> Void
        let styleUpdated: () -> Void
        let occlusionRawValue: () -> UInt
        let windowBelowTip: () -> UInt32
    }
    let environment: Environment
    private(set) var applicationReason = false
    private(set) var movementReason = false
    private(set) var wantsToBeVisible = false
    private(set) var correspondingWindowID: UInt32?
    init(environment: Environment) { self.environment = environment }
    private var overlay: Bool { applicationReason || movementReason }
    private func changeLevel(from previous: Bool) {
        guard previous != overlay else { return }
        if overlay {
            let number = environment.number()
            if number >= 1 { environment.setServerOverlayLevel(UInt32(number)) }
            environment.setLevel(102)
        } else { environment.setLevel(0) }
    }
    func setApplicationReason(_ enabled: Bool) {
        guard enabled != applicationReason else { return }
        let previous = overlay; applicationReason = enabled
        changeLevel(from: previous); refresh()
    }
    /// Immediate/full-completion branches clear just this tuple member before
    /// refreshing; they do not stop a newly configured cursor movement.
    func clearMovementReason() {
        guard movementReason else { return }
        let previous = overlay; movementReason = false; changeLevel(from: previous); refresh()
    }
    /// Does not clear a previous movement reason when overlay=false.
    func show(relativeTo id: UInt32?, overlay enabled: Bool) {
        wantsToBeVisible = true; correspondingWindowID = id
        if enabled { let previous = overlay; movementReason = true; changeLevel(from: previous) }
        refresh()
    }
    func retargetVisibleWindow(_ id: UInt32) {
        wantsToBeVisible = true; correspondingWindowID = id; refresh()
    }
    private func targetIsAvailable() -> Bool {
        guard let target = correspondingWindowID else { return true }
        return environment.visibleNumbers()?.contains(where: { UInt32(truncatingIfNeeded: $0) == target }) == true
    }
    /// Checks target availability even when an overlay reason is set.
    func refresh() {
        guard wantsToBeVisible, targetIsAvailable() else {
            stopMotion()
            if environment.isVisible() { environment.orderOut() }
            return
        }
        guard let target = correspondingWindowID, !overlay else { environment.front(); return }
        if let level = environment.targetLevel(target) { environment.setLevel(level) }
        environment.above(target)
    }
    /// Leaves wanted visibility and target intact, resets only the
    /// movement reason, and may re-run ordering after its motion cleanup.
    func stopMotion() {
        let previousMovement = movementReason, previous = overlay
        movementReason = false; changeLevel(from: previous)
        environment.stopMotion()
        if previousMovement && wantsToBeVisible && targetIsAvailable() { refresh() }
    }
    func hide() { wantsToBeVisible = false; refresh() }
    /// Releases the temporary overlay when the target lies below the tip.
    func moved() {
        guard movementReason else { return }
        let below = environment.windowBelowTip()
        if correspondingWindowID == below {
            let previous = overlay; movementReason = false; changeLevel(from: previous); refresh()
        }
    }
    func occlusionChanged() {
        defer { environment.styleUpdated() }
        guard environment.isVisible(), environment.occlusionRawValue() != 2,
              !overlay, let target = correspondingWindowID, let numbers = environment.visibleNumbers(),
              let cursorIndex = numbers.firstIndex(of: environment.number()),
              let targetIndex = numbers.firstIndex(of: Int(target)), cursorIndex >= targetIndex else { return }
        retargetVisibleWindow(target)
    }
    func activeSpaceChanged() { refresh() }
    func screenChanged(hasScreen: Bool) { if !hasScreen { stopMotion() } }
}
