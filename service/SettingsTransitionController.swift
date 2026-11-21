import Foundation
import CoreGraphics

/// Transition lifetime, retarget and delivery.
/// Shared production lifecycle; native renderer and scalar spring are
/// supplied by the permission transition adapter.
@MainActor final class SettingsTransitionController<Artwork: Sendable> {
    typealias Capture=SettingsAccessoryCapture<Artwork>
    enum Event { case value(CGFloat), finished, other }
    struct Spring {
        let period: Double=0.72
        let dampingFraction: Double=1
        let initialValue: Double=0
        let targetValue: Double=1
        let idleVelocityThreshold: Double?=nil
    }
    @MainActor class Overlay {
        let frame: @MainActor (CGRect) -> Void
        let radius: @MainActor (CGFloat) -> Void
        let progress: @MainActor (CGFloat) -> Void
        let targetArtwork: @MainActor (Artwork?) -> Void
        let alpha: @MainActor (CGFloat) -> Void
        let show: @MainActor () -> Void
        let close: @MainActor () -> Void
        init(frame: @escaping @MainActor (CGRect) -> Void,radius: @escaping @MainActor (CGFloat) -> Void,progress: @escaping @MainActor (CGFloat) -> Void,
             targetArtwork: @escaping @MainActor (Artwork?) -> Void,alpha: @escaping @MainActor (CGFloat) -> Void,show: @escaping @MainActor () -> Void,close: @escaping @MainActor () -> Void) {
            self.frame=frame;self.radius=radius;self.progress=progress;self.targetArtwork=targetArtwork;self.alpha=alpha;self.show=show;self.close=close
        }
    }
    @MainActor final class Animation {
        let setHandler: @MainActor ((@MainActor (Event) -> Void)?) -> Void
        let start: @MainActor () -> Void
        let stopImmediately: @MainActor () -> Void
        init(setHandler: @escaping @MainActor ((@MainActor (Event) -> Void)?) -> Void,start: @escaping @MainActor () -> Void,stopImmediately: @escaping @MainActor () -> Void) {
            self.setHandler=setHandler;self.start=start;self.stopImmediately=stopImmediately
        }
    }
    @MainActor struct Environment {
        let makeOverlay: @MainActor (Artwork?,Artwork?) -> Overlay
        let makeAnimation: @MainActor (Spring,Overlay) -> Animation
        var enqueueClose: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { operation in DispatchQueue.main.async(execute:operation) }
    }
    let environment: Environment
    private(set) var source: Capture?
    private(set) var target: Capture?
    private(set) var overlay: Overlay?
    private(set) var animation: Animation?
    private var completion: (@MainActor () -> Void)?
    init(environment: Environment) { self.environment=environment }
    func start(from source: Capture,to target: Capture,completion: @escaping @MainActor () -> Void) {
        stop()
        let overlay=environment.makeOverlay(source.artwork,target.artwork)
        overlay.frame(source.frameOnScreen.integral);overlay.radius(source.cornerRadius);overlay.progress(0);overlay.alpha(1);overlay.show()
        self.overlay=overlay;self.completion=completion
        var start=source,end=target
        start.frameOnScreen=start.frameOnScreen.integral;end.frameOnScreen=end.frameOnScreen.integral
        self.source=start;self.target=end
        let animation=environment.makeAnimation(.init(),overlay)
        animation.setHandler { [weak self,overlay] event in self?.receive(event,overlay:overlay) }
        self.animation=animation;animation.start()
    }
    func retarget(_ capture: Capture) {
        var capture=capture;capture.frameOnScreen=capture.frameOnScreen.integral
        target=capture;overlay?.targetArtwork(capture.artwork)
    }
    func stop() {
        if let animation { self.animation=nil;animation.setHandler(nil);animation.stopImmediately() }
        source=nil;target=nil
        overlay?.close();overlay=nil;completion=nil
    }
    private func receive(_ event: Event,overlay: Overlay) {
        switch event {
        case .value(let progress):
            guard let source,let target else { return }
            overlay.frame(SystemSettingsTransitionGeometry.frame(from:source.frameOnScreen,to:target.frameOnScreen,progress:progress).integral)
            overlay.radius(source.cornerRadius.addingProduct(progress,target.cornerRadius-source.cornerRadius))
            overlay.progress(progress)
        case .finished: finish()
        case .other: break
        }
    }
    private func finish() {
        if let animation { self.animation=nil;animation.setHandler(nil) }
        let old=overlay
        if let target {
            old?.frame(target.frameOnScreen.integral);old?.radius(target.cornerRadius);old?.targetArtwork(target.artwork)
        }
        old?.progress(1)
        let callback=completion;completion=nil;callback?()
        // Clear shared fields after the callback and queue closing the
        // retained old overlay. It has no reentrancy/generation safeguard.
        source=nil;target=nil;overlay=nil
        environment.enqueueClose { old?.close() }
    }
}
