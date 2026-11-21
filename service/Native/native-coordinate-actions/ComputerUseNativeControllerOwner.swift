import AppKit
import Foundation
import os

private final class ControllerOwnerStorage<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func get() -> Value { lock.withLock { stored } }
    func set(_ value: Value) {
        let previous = lock.withLock { let previous = stored; stored = value; return previous }
        withExtendedLifetime(previous) {}
    }
}

/// Full per-controller owner identity and constructor/lifecycle composition.
/// Native metadata/focus/cursor/capture providers remain explicit required seams.
/// No actor hop is inserted into the serial AX callback path.
final class ComputerUseNativeControllerOwner<Application: Sendable, Node: Sendable, Focus: Sendable,
    Assertion: Sendable, ImageFile: Hashable & Sendable, Cursor: Sendable, Tree: Sendable>: @unchecked Sendable {
    enum Analytics: Sendable { case started, ended }
    struct Environment: Sendable {
        let resolveIdentity: @MainActor @Sendable (ComputerUseApplicationTarget) throws -> (Application, Int32)
        let makeApplicationNode: @Sendable (Int32) -> Node
        let makeOrdering: @Sendable ([UInt32]) -> any ControllerOwnerOrdering
        let makeSignposter: @Sendable () -> OSSignposter
        let primaryWindow: @Sendable (Node) -> Node?
        let children: @Sendable (Node) -> [Node]
        let role: @Sendable (Node) -> String?
        let windowID: @Sendable (Node) throws -> UInt32
        let menuWindowID: @Sendable (Node) throws -> UInt32
        let actualPID: @Sendable (Node) throws -> Int32
        let sameElement: @Sendable (Node, Node) -> Bool
        let clearApplicationAttention: @Sendable (Node) -> Void
        let observeTermination: @Sendable (@escaping @Sendable (Notification) -> Void) -> any ControllerOwnerLifetime
        let terminatedPID: @Sendable (Notification) -> Int32?
        let observeAX: @Sendable (Int32, Node, @escaping @Sendable (Node, String) -> Void) throws -> any ControllerOwnerAXObservation<Node>
        let registerWeakOwner: @Sendable (AnyObject) -> Void
        let notificationCenter: NotificationCenter
        let analytics: @Sendable (Analytics) -> Void
        let acquireAccessibility: @Sendable (Node) -> Assertion?
        let releaseAccessibility: @Sendable (Assertion) -> Void
        let makeFocusEnforcer: @Sendable (Int32) -> Focus
        let deactivateFocusEnforcer: @Sendable (Focus) -> Void
        let setFocusEnforcerPID: @Sendable (Focus, Int32?) -> Void
        let clearFocusEnforcerPID: @Sendable (Focus) -> Void
        let scheduleOnMainActor: @Sendable (@escaping @MainActor @Sendable () async -> Void) -> Void
        let orderOutCursor: @MainActor @Sendable (Cursor) async -> Void
        let now: @Sendable () -> Date
        let sleep: @Sendable (TimeInterval) -> Void
    }
    static var didBecomeActive: Notification.Name { .init("computerUseAppControllerDidBecomeActive") }
    static var didBecomeInactive: Notification.Name { .init("computerUseAppControllerDidBecomeInactive") }
    let environment: Environment
    let chatID: String?
    let applicationTarget: ComputerUseApplicationTarget
    let bundleIdentifier: String
    let mcpRuntime: UInt8
    let isAXTreeDiffingEnabled: Bool
    let ordering: any ControllerOwnerOrdering
    let signposter: OSSignposter
    let runningApplication: Application
    let pid: Int32
    let app: Node
    private let active = ControllerOwnerStorage(false)
    private let last = ControllerOwnerStorage<(UInt32, Node)?>(nil)
    private let openedMenu = ControllerOwnerStorage<Node?>(nil)
    private let focusedMenuBarItem = ControllerOwnerStorage<Node?>(nil)
    private let focus = ControllerOwnerStorage<Focus?>(nil)
    private let assertion = ControllerOwnerStorage<Assertion?>(nil)
    private let cursor = ControllerOwnerStorage<Cursor?>(nil)
    private let images = ControllerOwnerStorage<Set<ImageFile>>([])
    private let tree = ControllerOwnerStorage<Tree?>(nil)
    private let needsSettle = ControllerOwnerStorage(false)
    private let visible = ControllerOwnerStorage(CGRect.null)
    private let scale = ControllerOwnerStorage(CGFloat.zero)
    private let screenSize = ControllerOwnerStorage(CGSize.zero)
    private let scaledCursor = ControllerOwnerStorage(ControllerScaledCursorPosition.zero)
    private var terminationObserver: (any ControllerOwnerLifetime)?
    private var windowObserver: (any ControllerOwnerAXObservation<Node>)?
    private var windowRegistry: ControllerAXWindowRegistry<Node>?

    var isActive: Bool { active.get() }
    var lastWindow: (UInt32, Node)? { get { last.get() } set { last.set(newValue) } }
    var currentlyOpenedMenu: Node? { get { openedMenu.get() } set { openedMenu.set(newValue) } }
    var currentlyFocusedMenuBarItem: Node? { get { focusedMenuBarItem.get() } set { focusedMenuBarItem.set(newValue) } }
    var focusEnforcer: Focus? { focus.get() }
    var accessibilityAssertion: Assertion? { assertion.get() }
    var virtualCursor: Cursor? { get { cursor.get() } set { cursor.set(newValue) } }
    var appSnapshotImageFiles: Set<ImageFile> { get { images.get() } set { images.set(newValue) } }
    var lastAXTree: Tree? { get { tree.get() } set { tree.set(newValue) } }
    var needsUISettleBeforeAppSnapshot: Bool { get { needsSettle.get() } set { needsSettle.set(newValue) } }
    var visibleRect: CGRect { get { visible.get() } set { visible.set(newValue) } }
    var scalingFactor: CGFloat { get { scale.get() } set { scale.set(newValue) } }
    var scaledScreenSize: CGSize { get { screenSize.get() } set { screenSize.set(newValue) } }
    var scaledCursorPosition: ControllerScaledCursorPosition { get { scaledCursor.get() } set { scaledCursor.set(newValue) } }
    var cursorPositionInScaledCoordinates: CGPoint {
        get { scaledCursorPosition.point }
        set { scaledCursorPosition = .init(x: Int64(newValue.x), y: Int64(newValue.y)) }
    }

    @MainActor init(target: ComputerUseApplicationTarget, chatID: String?, mcpRuntime: UInt8,
                    isAXTreeDiffingEnabled: Bool, environment: Environment) throws {
        self.environment = environment; applicationTarget = target; bundleIdentifier = target.bundleIdentifier
        self.chatID = chatID; self.mcpRuntime = mcpRuntime; self.isAXTreeDiffingEnabled = isAXTreeDiffingEnabled
        ordering = environment.makeOrdering([])
        signposter = environment.makeSignposter()
        let (application, resolvedPID) = try environment.resolveIdentity(target)
        guard resolvedPID > 0 else { throw ComputerUseControllerIdentityError.invalidProcessIdentifier(target.bundleIdentifier, resolvedPID) }
        runningApplication = application; pid = resolvedPID; app = environment.makeApplicationNode(resolvedPID)
        let registry = ControllerAXWindowRegistry<Node>(bundleIdentifier: bundleIdentifier, environment: .init(
            primaryWindow: { [weak self] in guard let self else { return nil }; return self.environment.primaryWindow(self.app) },
            children: environment.children, role: environment.role, windowID: environment.windowID,
            menuWindowID: environment.menuWindowID, actualPID: environment.actualPID, sameElement: environment.sameElement,
            publishOrderingIDs: { [weak self] in self?.ordering.observedWindowIDs = $0 },
            clearApplicationAttention: { [weak self] in if let self { self.environment.clearApplicationAttention(self.app) } },
            setOpenedMenu: { [weak self] in self?.currentlyOpenedMenu = $0 },
            setFocusedMenuBarItem: { [weak self] in self?.currentlyFocusedMenuBarItem = $0 },
            menuDidOpen: { [weak self] in self?.ordering.menuDidOpen() },
            menuDidClose: { [weak self] in self?.ordering.menuDidClose() },
            setFocusEnforcerPID: { [weak self] pid in
                guard let self, let focus = self.focusEnforcer else { return }; self.environment.setFocusEnforcerPID(focus, pid)
            }, clearFocusEnforcerPID: { [weak self] in
                guard let self, let focus = self.focusEnforcer else { return }; self.environment.clearFocusEnforcerPID(focus)
            }, now: environment.now, sleep: environment.sleep))
        windowRegistry = registry
        registry.seed()
        terminationObserver = environment.observeTermination { [weak self] notification in
            guard let self else { return }
            if let terminated = self.environment.terminatedPID(notification), terminated == self.pid, self.isActive { self.deactivate() }
            withExtendedLifetime(self) {}
        }
        let observation = try environment.observeAX(pid, app) { [weak self] element, name in
            guard let self else { return }
            if let notification = ControllerAXWindowRegistry<Node>.Notification(rawValue: name) {
                self.windowRegistry?.receive(notification, element: element)
            }
            withExtendedLifetime(self) {}
        }
        windowObserver = observation
        registry.setObservation(.init(registerDestroyed: { [weak observation] in try observation?.registerDestroyed($0) },
            removeDestroyed: { [weak observation] in try observation?.removeDestroyed($0) }))
        environment.registerWeakOwner(self)
    }

    func windows() -> [UInt32: ControllerAXWindowRegistry<Node>.Entry] { windowRegistry?.windows() ?? [:] }
    func activate() {
        guard !isActive else { return }
        active.set(true)
        environment.notificationCenter.post(name: Self.didBecomeActive, object: self)
        environment.analytics(.started)
        if accessibilityAssertion == nil { assertion.set(environment.acquireAccessibility(app)) }
        ordering.start()
    }
    @discardableResult func activateFocusEnforcer() -> Focus {
        if let existing = focusEnforcer { return existing }
        let created = environment.makeFocusEnforcer(pid)
        focus.set(created)
        return created
    }
    func deactivate() {
        guard isActive else { return }
        active.set(false)
        environment.notificationCenter.post(name: Self.didBecomeInactive, object: self)
        environment.analytics(.ended)
        if let focusEnforcer { environment.deactivateFocusEnforcer(focusEnforcer) }
        focus.set(nil)
        appSnapshotImageFiles = []
        currentlyOpenedMenu = nil
        currentlyFocusedMenuBarItem = nil
        if let accessibilityAssertion { environment.releaseAccessibility(accessibilityAssertion) }
        assertion.set(nil)
        environment.scheduleOnMainActor { [self] in
            if let virtualCursor { await environment.orderOutCursor(virtualCursor) }
        }
        ordering.stop()
    }
    deinit { terminationObserver?.cancel() }
}
