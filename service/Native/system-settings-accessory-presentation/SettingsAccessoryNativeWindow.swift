import AppKit

/// Native window configuration, layout, arrow and lifetime.
/// The SwiftUI content and foreground snapshot renderer are supplied
/// explicitly until their complete implementation is installed.
@MainActor final class SettingsAccessoryNativeWindow: NSPanel {
    let hostingContent: NSView
    private(set) var arrow: NSWindow?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(content: NSView,arrow: NSWindow) {
        self.hostingContent=content;self.arrow=nil
        super.init(contentRect:.zero,styleMask:.init(rawValue:32913),backing:.buffered,defer:false)
        let controller=NSViewController();controller.view=content
        hasShadow=true;level = .init(rawValue:3);contentViewController=controller
        isMovableByWindowBackground=false;isMovable=false;titleVisibility = .hidden
        titlebarAppearsTransparent=true;toolbarStyle = .unified
        backgroundColor=NSColor.white.withAlphaComponent(0.001);isOpaque=false
        collectionBehavior = .init(rawValue:586)
        addChildWindow(arrow,ordered:.above);self.arrow=arrow;positionArrow()
    }
    override func setFrame(_ frameRect: NSRect,display flag: Bool) {
        super.setFrame(frameRect,display:flag);positionArrow()
    }
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point);positionArrow() }
    private func positionArrow() { arrow?.setFrame(SettingsAccessoryLayout.arrowFrame(accessory:frame),display:false) }
    func presentationWindow<Artwork: Sendable>(capture: @escaping @MainActor (SettingsAccessoryNativeWindow) -> SettingsAccessoryCapture<Artwork>?) -> SettingsAccessoryPresentation<Artwork>.Window {
        .init(fittingSize:{ [self] in hostingContent.fittingSize },frameForContent:{ [self] in frameRect(forContentRect:$0) },
            setFrame:{ [self] in setFrame($0,display:false) },layout:{ [self] in layoutIfNeeded() },
            capture:{ [self] in capture(self) },setAlphas:{ [self] value in
                alphaValue=value;contentViewController?.view.alphaValue=value;arrow?.alphaValue=value
            },revealAfterForward:{ [self] in
                contentViewController?.view.alphaValue=1;arrow?.alphaValue=1;alphaValue=1
            },orderFront:{ [self] in orderFrontRegardless() },close:{ [self] in close() },
            completionTarget:{ [weak self] in
                guard let self else { return nil }
                return {
                    self.contentViewController?.view.alphaValue=1;self.arrow?.alphaValue=1
                    self.alphaValue=1;self.orderFrontRegardless()
                }
            })
    }
}
