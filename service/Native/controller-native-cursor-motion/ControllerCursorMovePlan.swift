import Foundation
import CoreGraphics

/// All origins are AppKit window-frame origins. The optional pet
/// position is already an AppKit screen hotspot, not a physical mouse sample.
struct ControllerCursorMovePlan: Sendable {
    let initialWindowOrigin: CGPoint
    let localStart: CGPoint
    let localEnd: CGPoint
    let destinationOrigin: CGPoint
    let capturedTargetOrigin: CGPoint?
    let wasVisible: Bool
    let animated: Bool
    let temporaryOverlay: Bool

    init(frame: CGRect, destinationOrigin: CGPoint, hotspot: CGPoint, petLocation: CGPoint?,
         wasVisible: Bool, animated: Bool, targetFrame: CGRect?, interpolatedOrigin: CGPoint?) {
        self.wasVisible = wasVisible; self.animated = animated; self.destinationOrigin = destinationOrigin
        let initial: CGPoint
        if wasVisible { initial = frame.origin }
        else if animated, let petLocation { initial = .init(x: petLocation.x-hotspot.x, y: petLocation.y-hotspot.y) }
        else { initial = destinationOrigin }
        initialWindowOrigin = initial
        capturedTargetOrigin = targetFrame?.origin
        let anchor = targetFrame?.origin ?? .zero
        localStart = interpolatedOrigin ?? .init(x: initial.x-anchor.x, y: initial.y-anchor.y)
        localEnd = .init(x: destinationOrigin.x-anchor.x, y: destinationOrigin.y-anchor.y)
        temporaryOverlay = !wasVisible && animated && petLocation != nil && initial != destinationOrigin
    }
    var globalStart: CGPoint {
        let anchor = capturedTargetOrigin ?? .zero
        return .init(x:localStart.x+anchor.x,y:localStart.y+anchor.y)
    }
    /// Keep this short-circuit order: even a previously visible move
    /// may skip animation when both hotspots miss its supplied target window.
    func shouldAnimate(windowIsVisible: () -> Bool, hasScreen: () -> Bool, aboveWindowID: UInt32?,
                       hotspot: CGPoint, hitWindow: (CGPoint) -> UInt32) -> Bool {
        guard animated else { return false }
        guard windowIsVisible() else { return false }
        guard hasScreen() else { return false }
        guard wasVisible || initialWindowOrigin != destinationOrigin else { return false }
        guard let target = aboveWindowID else { return true }
        let start = globalStart
        if hitWindow(.init(x:start.x+hotspot.x,y:start.y+hotspot.y)) == target { return true }
        return hitWindow(.init(x:destinationOrigin.x+hotspot.x,y:destinationOrigin.y+hotspot.y)) == target
    }
    static func needsFade(wasVisible: Bool, animated: Bool, fadeIn: Bool, didAnimate: Bool) -> Bool {
        !wasVisible && (animated || fadeIn) && !didAnimate
    }
    static func globalOrigin(local: CGPoint, currentTargetOrigin: CGPoint?) -> CGPoint {
        let origin = currentTargetOrigin ?? .zero
        return .init(x:local.x+origin.x,y:local.y+origin.y)
    }
}

/// The fade continuation belongs to its individual move. A subsequent move
/// must not discard that independent NSAnimationContext completion.
@MainActor final class ControllerCursorMoveReply {
    private var completion: ((Bool) -> Void)?
    private var fading = false
    init(_ completion: ((Bool) -> Void)?) { self.completion = completion }
    func moveFinished(_ completed: Bool) {
        guard !fading else { return }; finish(completed)
    }
    func deferToFade() { fading = true }
    func fadeFinished() { finish(true) }
    private func finish(_ completed: Bool) {
        let callback = completion; completion = nil; callback?(completed)
    }
}
