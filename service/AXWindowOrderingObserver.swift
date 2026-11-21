import AppKit
import ApplicationServices
import os

struct AXWindowMembership<Element: Hashable> {
    struct Entry: Equatable {
        let element: Element
        let isMenu: Bool
        let generation = UUID()
    }
    private(set) var entries: [CGWindowID: Entry] = [:]
    var ids: Set<CGWindowID> { Set(entries.keys) }

    // Windows are keyed by CGWindowID and retain their concrete kind.
    mutating func track(_ element: Element, id: CGWindowID) { entries[id] = Entry(element: element, isMenu: false) }
    mutating func trackMenu(_ element: Element, id: CGWindowID) { entries[id] = Entry(element: element, isMenu: true) }
    mutating func remove(_ element: Element) { entries = entries.filter { $0.value.element != element } }
    mutating func closeMenus() { entries = entries.filter { !$0.value.isMenu } }
    mutating func removeInvalid(_ invalid: [CGWindowID: Entry]) {
        for (id, entry) in invalid where entries[id] == entry { entries.removeValue(forKey: id) }
    }
}

// One newest-event buffer and one correction task per automation app.
final class AXWindowOrderingObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let bundle: String
    private let pid: pid_t
    private let processKey: String
    private let stream = AsyncStream<CGWindowID>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var windows = AXWindowMembership<AXUIElement>()
    private var subscribedIDs: Set<CGWindowID> = []
    private var subscription: RemoteHostedPIPWindowServerObserver?
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var pruning = false

    init(bundle: String, pid: pid_t, processKey: String) {
        self.bundle = bundle
        self.pid = pid
        self.processKey = processKey
    }

    deinit { stop() }

    func seed(observer: AXObserver?) {
        guard live else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let primary = AX.primaryWindow(application) else { return }
        var pending = [primary]
        var seen = Set<AXUIElement>()
        while let element = pending.popLast(), live {
            guard seen.insert(element).inserted else { continue }
            track(element, observer: observer)
            pending += AX.children(element).filter { AX.string($0, kAXRoleAttribute as String) == kAXSheetRole as String }
        }
    }

    func track(_ element: AXUIElement, observer: AXObserver?) {
        guard live, let id = try? AccessibilityWindowSPI.windowID(element) else { return }
        mutateWindows { $0.track(element, id: id) }
        if let observer {
            let status = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
            if status == .invalidUIElement { remove(element) }
        }
    }

    func remove(_ element: AXUIElement) {
        mutateWindows { $0.remove(element) }
    }

    func prune() {
        let snapshot = lock.withLock { () -> [CGWindowID: AXWindowMembership<AXUIElement>.Entry]? in
            guard !stopped, !pruning else { return nil }
            pruning = true
            return windows.entries
        }
        guard let snapshot else { return }
        defer { lock.withLock { pruning = false } }
        // Validity is the raw AX window ID; zero
        // and query errors both discard an ordinary or menu entry.
        let invalid = snapshot.filter { ((try? AccessibilityWindowSPI.windowID($0.value.element)) ?? 0) == 0 }
        mutateWindows { $0.removeInvalid(invalid) }
    }

    func pointerWindows() -> [(element: AXUIElement, id: CGWindowID, isMenu: Bool)] {
        prune()
        return lock.withLock {
            stopped ? [] : windows.entries.map { (element: $0.value.element, id: $0.key, isMenu: $0.value.isMenu) }
        }
    }

    func trackMenu(_ element: AXUIElement, id: CGWindowID?) -> Set<CGWindowID> {
        if let id { mutateWindows { $0.trackMenu(element, id: id) } }
        return lock.withLock { stopped ? [] : windows.ids }
    }

    func closeMenus() {
        mutateWindows { $0.closeMenus() }
    }

    private var live: Bool {
        guard lock.withLock({ !stopped }), let running = NSRunningApplication(processIdentifier: pid) else { return false }
        return !running.isTerminated && AppResolver.processKey(running) == processKey
    }

    private func mutateWindows(_ operation: (inout AXWindowMembership<AXUIElement>) -> Void) {
        lock.withLock {
            guard !stopped else { return }
            operation(&windows)
            let ids = windows.ids
            if ids != subscribedIDs { updateSubscription(ids) }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            worker?.cancel()
            worker = nil
            stream.continuation.finish()
            subscription = nil
            subscribedIDs = []
            windows = AXWindowMembership()
        }
    }

    private func updateSubscription(_ ids: Set<CGWindowID>) {
        guard !ids.isEmpty else { subscription = nil; subscribedIDs = []; return }
        let continuation = stream.continuation
        subscription = RemoteHostedPIPWindowServerObserver(windowIDs: ids, events: [.orderChanged]) { id, _ in
            continuation.yield(id)
        }
        subscribedIDs = subscription == nil ? [] : ids
        if worker == nil, subscription != nil {
            let events = stream.stream
            worker = Task.detached(priority: .userInitiated) { [weak self] in
                for await id in events { await self?.handleOrderChange(id) }
            }
        }
    }

    private func isObserved(_ id: CGWindowID) -> Bool {
        lock.withLock { !stopped && subscribedIDs.contains(id) }
    }

    private func handleOrderChange(_ id: CGWindowID) async {
        guard isObserved(id), !Task.isCancelled, !Permissions.screenLocked(),
              let session = AppSessions.shared.activeToken(for: bundle, process: processKey),
              let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
              AppResolver.processKey(target) == processKey,
              let owner = Self.windowOwner(id), let foreground = NSWorkspace.shared.frontmostApplication,
              owner != foreground.processIdentifier else { return }
        let application = AXUIElementCreateApplication(foreground.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let window = AX.axElement(AX.copy(application, kAXFocusedWindowAttribute as String)) else { return }
        let foregroundKey = AppResolver.processKey(foreground)
        let addedWindow = OSAllocatedUnfairLock(initialState: false)
        guard let observer = RemoteHostedPIPWindowServerObserver(windowIDs: nil, events: [.workspaceAddedWindow], onEvent: { id, _ in
            if Self.windowOwner(id) != nil { addedWindow.withLock { $0 = true } }
        }) else { return }
        defer { withExtendedLifetime(observer) {} }

        for _ in 0..<40 {
            guard !Task.isCancelled, isObserved(id), !target.isTerminated, !foreground.isTerminated,
                  !addedWindow.withLock({ $0 }),
                  let focused = AX.axElement(AX.copy(application, kAXFocusedWindowAttribute as String)),
                  CFEqual(focused, window), !Permissions.screenLocked(),
                  let current = NSWorkspace.shared.frontmostApplication,
                  AppResolver.processKey(current) == foregroundKey,
                  !addedWindow.withLock({ $0 }), !Task.isCancelled,
                  (try? AppSessions.shared.check(session)) != nil else { return }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return }
        }
    }

    private static func windowOwner(_ id: CGWindowID) -> pid_t? {
        guard let window = WindowDescription.lookup(id) else { return nil }
        return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }
}
