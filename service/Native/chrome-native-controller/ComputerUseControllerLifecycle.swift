import Foundation

/// Lifecycle portion of the per-controller owner. The Chrome caller
/// uses it on MainActor; this does not yet replace arbitrary-thread controllers.
@MainActor class ComputerUseControllerLifecycle<FocusEnforcer, AccessibilityAssertion, Menu, ImageFile: Hashable, Cursor> {
    enum Event: Equatable { case started, ended }
    static var didBecomeActive: Notification.Name { .init("computerUseAppControllerDidBecomeActive") }
    static var didBecomeInactive: Notification.Name { .init("computerUseAppControllerDidBecomeInactive") }
    struct Environment {
        let notificationCenter: NotificationCenter
        let recordAnalytics: @MainActor (Event) -> Void
        let acquireAccessibility: @MainActor () -> AccessibilityAssertion?
        let releaseAccessibility: @MainActor (AccessibilityAssertion) -> Void
        let startWindowOrdering: @MainActor () -> Void
        let stopWindowOrdering: @MainActor () -> Void
        let makeFocusEnforcer: @MainActor () -> FocusEnforcer
        let deactivateFocusEnforcer: @MainActor (FocusEnforcer) -> Void
        let scheduleOnMainActor: @MainActor (@escaping @MainActor () async -> Void) -> Void
        let orderOutCursor: @MainActor (Cursor) async -> Void
    }
    let environment: Environment
    private(set) var isActive = false
    private(set) var focusEnforcer: FocusEnforcer?
    private(set) var accessibilityAssertion: AccessibilityAssertion?
    var currentlyOpenedMenu: Menu?
    var currentlyFocusedMenuBarItem: Menu?
    var appSnapshotImageFiles: Set<ImageFile> = []
    var virtualCursor: Cursor?

    init(environment: Environment) { self.environment = environment }

    static func enqueueOnMainActor(_ operation: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await operation() }
    }

    final func activate() {
        guard !isActive else { return }
        isActive = true
        environment.notificationCenter.post(name: Self.didBecomeActive, object: self)
        environment.recordAnalytics(.started)
        if accessibilityAssertion == nil { accessibilityAssertion = environment.acquireAccessibility() }
        environment.startWindowOrdering()
    }

    @discardableResult final func activateFocusEnforcer() -> FocusEnforcer {
        if let focusEnforcer { return focusEnforcer }
        let result = environment.makeFocusEnforcer()
        focusEnforcer = result
        return result
    }

    final func deactivate() {
        guard isActive else { return }
        isActive = false
        environment.notificationCenter.post(name: Self.didBecomeInactive, object: self)
        environment.recordAnalytics(.ended)
        if let focusEnforcer { environment.deactivateFocusEnforcer(focusEnforcer) }
        focusEnforcer = nil
        appSnapshotImageFiles.removeAll()
        currentlyOpenedMenu = nil
        currentlyFocusedMenuBarItem = nil
        if let accessibilityAssertion { environment.releaseAccessibility(accessibilityAssertion) }
        accessibilityAssertion = nil
        // Read the CURRENT cursor when the queued task runs. The task
        // retains the controller, has no activation/generation filter, and may
        // hide a replacement cursor after a subsequent activation.
        environment.scheduleOnMainActor { [self] in
            if let virtualCursor { await environment.orderOutCursor(virtualCursor) }
        }
        environment.stopWindowOrdering()
    }
}
