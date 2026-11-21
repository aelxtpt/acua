import Foundation
import CoreGraphics

/// Rendering and
/// capture have explicit owners; no placeholder animation substitutes for them.
@MainActor final class SettingsAccessoryPresentation<Artwork: Sendable>: SystemSettingsWindowTrackingObserver {
    typealias Capture=SettingsAccessoryCapture<Artwork>
    struct Permission { let identifier: String;let isScreenRecording: Bool }
    enum Phase: UInt8 { case pending, presented, returning }
    struct Session { var source: Capture;var target: Capture?;var phase: Phase }
    final class Window {
        let fittingSize: () -> CGSize
        let frameForContent: (CGRect) -> CGRect
        let setFrame: (CGRect) -> Void
        let layout: () -> Void
        let capture: () -> Capture?
        let setAlphas: (CGFloat) -> Void
        let revealAfterForward: () -> Void
        let orderFront: () -> Void
        let close: () -> Void
        private let completionProvider: (() -> (() -> Void)?)?
        init(fittingSize: @escaping () -> CGSize,frameForContent: @escaping (CGRect) -> CGRect,
             setFrame: @escaping (CGRect) -> Void,layout: @escaping () -> Void,capture: @escaping () -> Capture?,
             setAlphas: @escaping (CGFloat) -> Void,revealAfterForward: @escaping () -> Void,
             orderFront: @escaping () -> Void,close: @escaping () -> Void,completionTarget: (() -> (() -> Void)?)? = nil) {
            self.fittingSize=fittingSize;self.frameForContent=frameForContent;self.setFrame=setFrame;self.layout=layout;self.capture=capture
            self.setAlphas=setAlphas;self.orderFront=orderFront;self.close=close
            self.revealAfterForward=revealAfterForward
            completionProvider=completionTarget
        }
        var forwardCompletionTarget: () -> (() -> Void)? {
            if let completionProvider { return completionProvider }
            return { [weak self] in
                guard let self else { return nil }
                return { self.revealAfterForward();self.orderFront() }
            }
        }
    }
    final class Transition {
        let start: (Capture,Capture,@escaping @MainActor () -> Void) -> Void
        let retarget: (Capture) -> Void
        let stop: () -> Void
        init(start: @escaping (Capture,Capture,@escaping @MainActor () -> Void) -> Void,
             retarget: @escaping (Capture) -> Void,stop: @escaping () -> Void) {
            self.start=start;self.retarget=retarget;self.stop=stop
        }
    }
    struct Environment {
        let permission: () -> Permission?
        let firstScreenHeight: () -> CGFloat?
        let hasObservedWindow: () -> Bool
        let lastWindow: () -> SystemSettingsWindowRecord?
        let heading: (SystemSettingsWindowRecord) -> CGRect?
        let withoutTransition: () -> Bool
        let makeWindow: (Permission,@escaping @MainActor () -> Void,@escaping @MainActor (CGPoint) -> Void) -> Window
        let makeTransition: () -> Transition
        let clearTracking: () -> Void
        let activateApplication: () -> Void
        let activateSettings: () -> Void
        let transitionStarted: () -> Void
        let reverseCompleted: () -> Void
        let cancelDrag: () -> Void
        let completeDrop: () -> Void
    }
    let environment: Environment
    private(set) var session: Session?
    private(set) var window: Window?
    private(set) var transition: Transition?
    init(environment: Environment) { self.environment=environment }
    func prepare(source: Capture?,transitionsEnabled: Bool) {
        session=transitionsEnabled ? source.map { Session(source:$0,target:nil,phase:.pending) }:nil
    }
    func cleanup() {
        transition?.stop();transition=nil;session=nil
        window?.close();window=nil
    }
    func settingsWindowChanged(_ current: SystemSettingsWindowRecord?,applicationIsActive: Bool) {
        guard let permission=environment.permission() else { cleanup();return }
        guard let current else {
            if environment.hasObservedWindow() { cancelForMissingWindow() }
            return
        }
        guard applicationIsActive else { cleanup();return }
        let accessory: Window
        if let window { accessory=window }
        else {
            accessory=environment.makeWindow(permission,{ [weak self] in self?.back() },{ [weak self] in self?.drop(at:$0) })
            window=accessory
        }
        guard let screenHeight=environment.firstScreenHeight() else { return }
        let content=SettingsAccessoryLayout.contentFrame(windowQuartz:current.frame,primaryScreenHeight:screenHeight,
            fittingSize:accessory.fittingSize(),audioHeading:permission.isScreenRecording ? environment.heading(current):nil)
        let frame=accessory.frameForContent(content).integral
        accessory.setFrame(frame);accessory.layout()
        guard let target=accessory.capture() else { return }
        if session?.phase == .returning { return }
        if session != nil { session?.target=target }
        if let transition { transition.retarget(target);return }
        if let saved=session,saved.phase == .pending,!environment.withoutTransition() {
            accessory.setAlphas(0)
            let controller=environment.makeTransition();transition=controller
            environment.transitionStarted()
            let completionTarget=accessory.forwardCompletionTarget
            controller.start(saved.source,target) { [weak self] in
                guard let self,let reveal=completionTarget() else { return }
                // Completion clears the current shared controller,
                // without an identity filter, then updates the current session.
                transition=nil
                if session != nil { session?.phase = .presented }
                reveal();environment.activateSettings()
            }
            return
        }
        if var saved=session,saved.phase == .pending {
            environment.transitionStarted();saved.phase = .presented;session=saved
        }
        accessory.setFrame(frame);accessory.setAlphas(1);accessory.orderFront();environment.activateSettings()
    }
    func back() {
        environment.clearTracking();environment.activateApplication()
        guard var saved=session,saved.phase == .presented,let window,
              let departure=window.capture() ?? saved.target else { cancelForMissingWindow();return }
        saved.phase = .returning;session=saved
        transition?.stop()
        let controller=environment.makeTransition();transition=controller
        window.setAlphas(0)
        controller.start(departure,saved.source) { [weak self] in self?.finishReverse() }
    }
    func cancelForMissingWindow() {
        environment.clearTracking();cleanup();environment.activateApplication();environment.cancelDrag()
    }
    private func finishReverse() {
        transition=nil;environment.reverseCompleted();cleanup();environment.activateApplication();environment.cancelDrag()
    }
    func drop(at point: CGPoint) {
        guard let current=environment.lastWindow(),let height=environment.firstScreenHeight(),
              SettingsAccessoryLayout.acceptsDrop(point,windowQuartz:current.frame,primaryScreenHeight:height) else { return }
        environment.clearTracking();cleanup();environment.completeDrop()
    }
}
