import AppKit
import ApplicationServices

struct AXMenuFocus<Element> {
    private(set) var root: Element?
    private var synthetic = false

    mutating func opened(_ item: Element?, synthetic: Bool = false) {
        guard let item else { return }
        root = item
        self.synthetic = synthetic
    }

    mutating func closed() { root = nil; synthetic = false }

    mutating func closeSynthetic() {
        if synthetic { closed() }
    }

    static func selectBarItem(_ item: Element, role: (Element) -> String?, children: (Element) -> [Element],
                              enforceFocus: () throws -> Void, commit: (Element) throws -> Void) throws -> Bool {
        guard role(item) == kAXMenuBarItemRole as String,
              children(item).contains(where: { role($0) == kAXMenuRole as String }) else { return false }
        try enforceFocus()
        try commit(item)
        return true
    }

    static func barItem(containing element: Element, role: (Element) -> String?, parent: (Element) -> Element?) -> Element? {
        var candidate = element
        for _ in 0..<16 {
            guard let kind = role(candidate), let ancestor = parent(candidate) else { return nil }
            if kind == kAXMenuBarItemRole as String {
                return role(ancestor) == kAXMenuBarRole as String ? candidate : nil
            }
            guard kind == kAXMenuRole as String || kind == kAXMenuItemRole as String else { return nil }
            candidate = ancestor
        }
        return nil
    }
}

enum AXMenuSessions {
    private final class Session {
        let processKey: String
        let pid: pid_t
        let observer: AXObserver?
        let ordering: AXWindowOrderingObserver
        var focus = AXMenuFocus<AXUIElement>()
        var menuOrdering: Task<Void, Never>?
        var menuGeneration: UUID?
        var accessibilityAssertion: AXAccessibilityTracker.Lease?

        init(bundle: String, processKey: String, pid: pid_t, observer: AXObserver?) {
            self.processKey = processKey
            self.pid = pid
            self.observer = observer
            ordering = AXWindowOrderingObserver(bundle: bundle, pid: pid, processKey: processKey)
        }

        deinit {
            menuOrdering?.cancel()
            if let observer { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observer)) }
        }

        func cancelMenuOrdering(closeMenus: Bool = true) {
            menuOrdering?.cancel()
            menuOrdering = nil
            menuGeneration = nil
            if closeMenus { ordering.closeMenus() }
        }

        func invalidate() {
            ordering.stop()
            cancelMenuOrdering()
        }
    }

    private static let lock = NSLock()
    private static var sessions: [String: Session] = [:]
    private static var shuttingDown = false

    static func observe(_ app: ResolvedApp, holdAccessibility: Bool = false) {
        let key = AppResolver.processKey(app.running)
        let bundle = app.bundleIdentifier
        guard !app.running.isTerminated else { return }
        let (stopped, current) = lock.withLock { (shuttingDown, sessions[bundle]) }
        guard !stopped else { return }
        if let current, current.processKey == key {
            if holdAccessibility { retainAccessibility(for: app, session: current) }
            current.ordering.prune()
            return
        }
        let pid = app.running.processIdentifier
        let callback: AXObserverCallback = { observer, element, notification, _ in
            AXMenuSessions.receive(observer, element: element, notification: notification as String)
        }
        var observer: AXObserver?
        if AXObserverCreate(pid, callback, &observer) == .success, let observer {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 1)
            AXObserverAddNotification(observer, application, kAXMenuOpenedNotification as CFString, nil)
            AXObserverAddNotification(observer, application, kAXMenuClosedNotification as CFString, nil)
            AXObserverAddNotification(observer, application, kAXWindowCreatedNotification as CFString, nil)
            AXObserverAddNotification(observer, application, kAXSheetCreatedNotification as CFString, nil)
            AXObserverAddNotification(observer, application, kAXWindowMovedNotification as CFString, nil)
            AXObserverAddNotification(observer, application, kAXWindowResizedNotification as CFString, nil)
        }
        let session = Session(bundle: bundle, processKey: key, pid: pid, observer: observer)
        let (admitted, previous) = lock.withLock { () -> (Bool, Session?) in
            guard !shuttingDown, !app.running.isTerminated, sessions[bundle]?.processKey != key else { return (false, nil) }
            let previous = sessions.updateValue(session, forKey: bundle)
            previous?.invalidate()
            return (true, previous)
        }
        guard admitted else { return }
        if let observer { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        withExtendedLifetime(previous) {}
        if holdAccessibility { retainAccessibility(for: app, session: session) }
        if app.running.isTerminated { processTerminated(key) }
        else { session.ordering.seed(observer: observer) }
    }

    private static func retainAccessibility(for app: ResolvedApp, session: Session) {
        let bundle = app.bundleIdentifier
        guard let token = AppSessions.shared.activeToken(for: bundle, process: session.processKey),
              lock.withLock({ sessions[bundle] === session && session.accessibilityAssertion == nil }),
              let lease = AXAccessibility.acquire(for: app) else { return }
        let retained = lock.withLock {
            guard sessions[bundle] === session, session.accessibilityAssertion == nil,
                  (try? AppSessions.shared.check(token)) != nil else { return false }
            session.accessibilityAssertion = lease
            return true
        }
        if !retained { lease.release() }
    }

    static func releaseAccessibility(_ bundle: String) {
        let lease = lock.withLock {
            let lease = sessions[bundle]?.accessibilityAssertion
            sessions[bundle]?.accessibilityAssertion = nil
            return lease
        }
        lease?.release()
    }

    static func end(_ bundle: String) {
        let previous = lock.withLock {
            let previous = sessions.removeValue(forKey: bundle)
            previous?.invalidate()
            return previous
        }
        withExtendedLifetime(previous) {}
    }

    static func processTerminated(_ processKey: String) {
        let previous = lock.withLock {
            let matches = sessions.filter { $0.value.processKey == processKey }
            for (bundle, session) in matches {
                session.invalidate()
                sessions.removeValue(forKey: bundle)
            }
            return matches
        }
        withExtendedLifetime(previous) {}
    }

    static func endAll() {
        let previous = lock.withLock {
            shuttingDown = true
            let previous = sessions
            for session in previous.values { session.invalidate() }
            sessions.removeAll()
            return previous
        }
        withExtendedLifetime(previous) {}
    }

    static func root(for app: ResolvedApp, application: AXUIElement) -> AXUIElement? {
        let key = AppResolver.processKey(app.running)
        let root = lock.withLock { () -> AXUIElement? in
            guard let session = sessions[app.bundleIdentifier], session.processKey == key else { return nil }
            return session.focus.root
        }
        if let root, barItem(root, pid: app.running.processIdentifier) != nil { return root }
        guard let focused = AX.axElement(AX.copy(application, kAXFocusedUIElementAttribute as String)) else { return nil }
        if AX.string(focused, kAXRoleAttribute as String) == kAXMenuBarItemRole as String,
           AX.copy(focused, kAXSelectedAttribute as String) as? Bool != true { return nil }
        return barItem(focused, pid: app.running.processIdentifier)
    }

    static func pointerWindows(pid: pid_t) -> [(element: AXUIElement, id: CGWindowID, isMenu: Bool)] {
        guard let session = lock.withLock({ sessions.values.first { $0.pid == pid } }),
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              AppResolver.processKey(running) == session.processKey else { return [] }
        return session.ordering.pointerWindows()
    }

    static func activate(_ item: AXUIElement, bundle: String) {
        guard AX.string(item, kAXRoleAttribute as String) == kAXMenuBarItemRole as String,
              let session = lock.withLock({ sessions[bundle] }), let root = barItem(item, pid: session.pid) else { return }
        lock.withLock { session.focus.opened(root) }
    }

    static func select(_ item: AXUIElement, bundle: String) throws -> Bool {
        let expected = lock.withLock { sessions[bundle] }
        return try AXMenuFocus.selectBarItem(item, role: { AX.string($0, kAXRoleAttribute as String) }, children: AX.children,
            enforceFocus: {
                let app = try AppResolver.require(bundle)
                guard let expected, expected.processKey == AppResolver.processKey(app.running) else {
                    throw ServiceError(.noActiveSession, "Menu session changed before focus activation")
                }
                let application = AXUIElementCreateApplication(app.running.processIdentifier)
                AXUIElementSetMessagingTimeout(application, 1)
                let window = AXIndex.shared.snapshot(for: bundle)?.windowElement
                    ?? AX.axElement(AX.copy(application, kAXFocusedWindowAttribute as String))
                    ?? AX.axElement(AX.copy(application, kAXMainWindowAttribute as String))
                try SyntheticFocusSessions.enforce(app: app, window: window)
                try RequestRuntime.check()
            }, commit: { root in
                try lock.withLock {
                    guard let session = sessions[bundle], session === expected else {
                        throw ServiceError(.noActiveSession, "Menu session ended during focus activation")
                    }
                    session.focus.opened(root, synthetic: true)
                }
            })
    }

    static func close(_ bundle: String) {
        lock.withLock { sessions[bundle]?.focus.closed() }
    }

    static func closeSynthetic(_ bundle: String) {
        lock.withLock { sessions[bundle]?.focus.closeSynthetic() }
    }

    private static func receive(_ observer: AXObserver, element: AXUIElement, notification: String) {
        precondition(Thread.isMainThread)
        guard let (bundle, session) = lock.withLock({
            sessions.first { $0.value.observer.map { CFEqual($0, observer) } == true }
        }) else { return }
        if notification == kAXWindowCreatedNotification as String || notification == kAXSheetCreatedNotification as String {
            if let target = NSRunningApplication(processIdentifier: session.pid),
               !target.isTerminated, AppResolver.processKey(target) == session.processKey,
               lock.withLock({ sessions[bundle] === session }),
               AppSessions.shared.activeToken(for: bundle, process: session.processKey) != nil {
                ApplicationRegistrySPI.clearAttention(for: session.pid)
            }
            let ordering = session.ordering
            Task.detached(priority: .userInitiated) { ordering.track(element, observer: observer) }
        } else if notification == kAXUIElementDestroyedNotification as String {
            session.ordering.remove(element)
            AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
        } else if notification == kAXWindowMovedNotification as String || notification == kAXWindowResizedNotification as String {
            let ordering = session.ordering
            Task.detached(priority: .userInitiated) { ordering.prune() }
        } else if notification == kAXMenuClosedNotification as String {
            let active = lock.withLock {
                guard sessions[bundle] === session else { return false }
                session.focus.closed()
                session.cancelMenuOrdering(closeMenus: false)
                session.ordering.remove(element)
                return true
            }
            if active { SyntheticFocusSessions.menuClosed(bundle: bundle, processKey: session.processKey) }
        } else if notification == kAXMenuOpenedNotification as String {
            let root = barItem(element, pid: session.pid)
            let menuPID = try? AccessibilityWindowSPI.actualPID(element)
            let menuID = AXMenuWindowOrder.windowID(element, knownPID: menuPID)
            let foreground = NSWorkspace.shared.frontmostApplication
            let pid = session.pid
            let token = AppSessions.shared.activeToken(for: bundle, process: session.processKey)
            let generation = UUID()
            let active = lock.withLock {
                guard sessions[bundle] === session else { return false }
                session.focus.opened(root)
                session.cancelMenuOrdering(closeMenus: false)
                // Registration is independent of a capture/action token. The
                // delayed restoration can refine a WindowServer publication race.
                _ = session.ordering.trackMenu(element, id: menuID)
                if let token {
                    session.menuGeneration = generation
                    session.menuOrdering = Task.detached(priority: .userInitiated) {
                        await AXMenuWindowOrder.restore(foreground: foreground, targetPID: pid, session: token,
                                                        menu: element, menuPID: menuPID) { id in
                            lock.withLock {
                                guard let current = sessions[bundle], current.menuGeneration == generation else { return [] }
                                return current.ordering.trackMenu(element, id: id)
                            }
                        }
                    }
                }
                return true
            }
            if active {
                SyntheticFocusSessions.menuOpened(bundle: bundle, processKey: session.processKey, menuPID: menuPID)
            }
        }
    }

    private static func barItem(_ element: AXUIElement, pid: pid_t) -> AXUIElement? {
        guard let root = AXMenuFocus.barItem(containing: element, role: { AX.string($0, kAXRoleAttribute as String) },
                                            parent: { AX.axElement(AX.copy($0, kAXParentAttribute as String)) }) else { return nil }
        var owner: pid_t = 0
        return AXUIElementGetPid(root, &owner) == .success && owner == pid ? root : nil
    }
}
