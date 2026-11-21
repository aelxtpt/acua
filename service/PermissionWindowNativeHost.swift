import AppKit

/// AppKit effects of the permission window. Creation is explicit; compiling
/// this adapter does not construct a window or start native permission access.
@MainActor final class PermissionWindowNativeHost: NSObject, PermissionWindowHosting, NSWindowDelegate {
    struct Configuration: Equatable, Sendable {
        var styleMask: UInt = 32771
        var backing: UInt = 2
        var backgroundAlpha: Double = 0.001
        var titleVisibilityHidden = true
        var titlebarTransparent = true
        var movableByWindowBackground = true
        var releasedWhenClosed = false
        var opaque = false
    }
    static let configuration = Configuration()
    let controller: NSWindowController
    var didClose: (@MainActor @Sendable () -> Void)?
    private init(controller: NSWindowController) { self.controller = controller; super.init() }
    static func make(title: String, content: NSView) -> PermissionWindowNativeHost {
        let c = configuration
        let window = NSWindow(contentRect: .zero, styleMask: .init(rawValue: c.styleMask),
            backing: NSWindow.BackingStoreType(rawValue: c.backing)!, defer: false)
        window.title = title + " Permissions"
        window.titleVisibility = c.titleVisibilityHidden ? .hidden : .visible
        window.titlebarAppearsTransparent = c.titlebarTransparent
        window.isMovableByWindowBackground = c.movableByWindowBackground
        window.isReleasedWhenClosed = c.releasedWhenClosed
        window.backgroundColor = .white.withAlphaComponent(c.backgroundAlpha)
        window.isOpaque = c.opaque
        window.contentView = content
        let host = PermissionWindowNativeHost(controller: NSWindowController(window: window))
        window.delegate = host
        return host
    }
    func currentWindow() -> (any PermissionWindowPresenting)? {
        guard let window = controller.window else { return nil }
        return CapturedWindow(controller: controller, window: window)
    }
    func windowWillClose(_ notification: Notification) { didClose?() }

    @MainActor private final class CapturedWindow: PermissionWindowPresenting {
        let controller: NSWindowController
        let window: NSWindow
        private lazy var content: NSView? = window.contentView
        init(controller: NSWindowController, window: NSWindow) {
            self.controller = controller; self.window = window
        }
        var hasContent: Bool { content != nil }
        var isVisible: Bool { window.isVisible }
        func layoutAndFit() {
            guard let content else { return }
            content.layoutSubtreeIfNeeded(); window.setContentSize(content.fittingSize)
        }
        func center() { window.center() }
        func setLevel(_ level: Int) { window.level = .init(rawValue: level) }
        func closeWaiter() -> PermissionWindowCloseWaiter {
            let notifications = NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: window)
            return { let iterator = notifications.makeAsyncIterator(); return await iterator.next() != nil }
        }
        func activateApplication() { NSApp.activate(ignoringOtherApps: true) }
        // showWindow acts on the controller, while the explicit
        // front/level/center/notification calls keep the captured window.
        func show() { controller.showWindow(nil) }
        func makeKeyAndOrderFront() { window.makeKeyAndOrderFront(nil) }
        func close() { window.close() }
    }
}
