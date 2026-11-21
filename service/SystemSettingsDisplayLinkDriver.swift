import AppKit
import QuartzCore

@MainActor protocol SystemSettingsDisplayLinkObject: AnyObject {
    var timestamp: CFTimeInterval { get }
    var duration: CFTimeInterval { get }
    var targetTimestamp: CFTimeInterval { get }
    func add(to runloop: RunLoop,forMode mode: RunLoop.Mode)
    func invalidate()
}
extension CADisplayLink: SystemSettingsDisplayLinkObject {}

/// Uses the source's native display link, with
/// no synthetic rate, elapsed-time substitution or timer fallback.
@MainActor final class SystemSettingsDisplayLinkDriver: NSObject {
    var frameCallback: (@MainActor @Sendable (SystemSettingsAnimationFrame) -> Void)?
    private(set) var isActive=false
    private var link: (any SystemSettingsDisplayLinkObject)?
    init(makeLink: (AnyObject,Selector) -> any SystemSettingsDisplayLinkObject) {
        super.init()
        link=makeLink(self,#selector(displayLinkDidFire))
    }
    convenience init(window: NSWindow) {
        self.init { target,selector in window.displayLink(target:target,selector:selector) }
    }
    convenience init(screen: NSScreen) {
        self.init { target,selector in screen.displayLink(target:target,selector:selector) }
    }
    func start() {
        guard !isActive else { return }
        isActive=true
        guard let link else { preconditionFailure("Display link was not initialized") }
        link.add(to:.current,forMode:.common)
    }
    func stop() {
        guard isActive else { return }
        isActive=false
        guard let link else { preconditionFailure("Display link was not initialized") }
        link.invalidate()
    }
    @objc func displayLinkDidFire() {
        guard let callback=frameCallback else { return }
        guard let link else { preconditionFailure("Display link was not initialized") }
        let timestamp=link.timestamp,duration=link.duration,target=link.targetTimestamp
        callback(.init(timestamp:timestamp,duration:duration,targetTimestamp:target))
    }
    isolated deinit {
        if isActive { isActive=false;link?.invalidate() }
    }
}
