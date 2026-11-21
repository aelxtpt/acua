import Foundation

/// One process-wide optional manager behind static entry points.
/// Registration appends; PID removal removes only the first entry.
final class ControllerGlobalFocusRegistry<Event: Sendable>: @unchecked Sendable {
    typealias Manager = ControllerGlobalFocusManager<Event>
    private let lock = NSLock()
    private var instance: Manager?
    private let environment: Manager.Environment
    init(environment: Manager.Environment) { self.environment = environment }
    var manager: Manager? { lock.withLock { instance } }
    func start(pid: Int32, lost: (@Sendable () -> Void)?, gained: (@Sendable () -> Void)?) {
        let manager: Manager
        if let existing = self.manager { manager = existing }
        else {
            manager = Manager(environment:environment)
            lock.withLock { instance = manager }
        }
        manager.append(pid:pid,lost:lost,gained:gained)
    }
    func stop(pid: Int32) {
        guard let manager else { return }
        manager.removeFirst(pid:pid) { self.lock.withLock { self.instance = nil } }
    }
    func isFocused(_ pid: Int32) -> Bool {
        if let manager { return manager.state.current.app == pid }
        return environment.currentFocus().app == pid
    }
    func startMenu(pid: Int32, menuPID: Int32?) { manager?.startMenu(pid:pid,menuPID:menuPID) }
    func stopMenu(pid: Int32) { manager?.stopMenu(pid:pid) }
}

final class ControllerGlobalFocusManager<Event: Sendable>: @unchecked Sendable {
    typealias Focus = ControllerKeyboardFocusState.Focus
    typealias Handler = @Sendable () -> Void
    enum ProcessKind: Sendable { case application, service }
    struct Environment: Sendable {
        let makeTap: @Sendable (ControllerFocusTapConfiguration) -> any ControllerFocusTap<Event>
        let currentFocus: @Sendable () -> Focus
        let bridgePID: @Sendable () -> Int32?
        let resolve: @Sendable (Int32) -> Focus
        let processIdentifier: @Sendable () -> Int32
        let integer: @Sendable (Event, UInt32) -> Int64
        let noticeField: UInt32?
        let noticePIDField: UInt32?
        let releaseTokenField: UInt32?
        let windowField: UInt32?
        let windowOwner: @Sendable (UInt32) -> Int32?
        let post: @Sendable (Event, Int32) -> Void
        let enqueueCallback: @Sendable (@escaping Handler) -> Void
        let previousFocusedProcess: @Sendable (Int32) -> ProcessKind?
        let releaseFocus: @Sendable (UInt32) -> Bool
        let repairHost: @Sendable (Int32) -> Void
    }
    private struct Entry: Sendable {
        let pid: Int32
        let lost: Handler?
        let gained: Handler?
        let keyboard: any ControllerFocusTap<Event>
        var menu: [any ControllerFocusTap<Event>] = []
        var suppressesMenu = false
    }
    private let environment: Environment
    private let entriesLock = NSLock()
    private var entries: [Entry] = []
    private let stateLock = NSLock()
    private var stored: ControllerKeyboardFocusState
    private var globalTap: (any ControllerFocusTap<Event>)?
    private var bridgeKeyboard: (any ControllerFocusTap<Event>)?
    private let bridgePID: Int32?

    init(environment: Environment) {
        self.environment = environment
        stored = .init(environment.currentFocus())
        bridgePID = environment.bridgePID()
        let global = environment.makeTap(.init(location:.annotatedSession,types:[21],tail:true,listenOnly:false))
        globalTap = global
        global.start { [weak self] _, event in
            guard let self else { return event }
            return self.notice(event)
        }
        if let bridgePID { bridgeKeyboard = keyboard(pid:bridgePID) }
    }
    var state: ControllerKeyboardFocusState { stateLock.withLock { stored } }
    var protectedPIDs: [Int32] { entriesLock.withLock { entries.map(\.pid) } }
    var menuEnabledPIDs: [Int32] { entriesLock.withLock { entries.filter(\.suppressesMenu).map(\.pid) } }
    private func keyboard(pid: Int32) -> any ControllerFocusTap<Event> {
        let service = environment.processIdentifier()
        let tap = environment.makeTap(.init(location:.process(pid),types:[10,11,12],tail:true,listenOnly:false))
        tap.start { [weak self] _, event in
            guard let self else { return event }
            guard Int32(self.environment.integer(event,41)) != service else { return event }
            return self.stateLock.withLock {
                guard let recipient = self.stored.keyboardRecipient(target:Int32(self.environment.integer(event,40))) else { return event }
                self.environment.post(event,recipient)
                return nil
            }
        }
        return tap
    }
    func append(pid: Int32, lost: Handler?, gained: Handler?) {
        let tap = keyboard(pid:pid)
        entriesLock.withLock { entries.append(.init(pid:pid,lost:lost,gained:gained,keyboard:tap)) }
    }
    func removeFirst(pid: Int32, empty: () -> Void) {
        entriesLock.withLock {
            guard let index = entries.firstIndex(where:{$0.pid == pid}) else { return }
            entries.remove(at:index)
            if entries.isEmpty { empty() }
        }
    }
    func startMenu(pid: Int32, menuPID: Int32?) {
        // Build before looking up the entry, including when PID is unregistered.
        let taps = [pid,menuPID].compactMap{$0}.map { receiver in
            let tap = environment.makeTap(.init(location:.process(receiver),types:[1,2,6,3,4,7,25,26,27],tail:false,listenOnly:false))
            tap.start { [weak self] _, event in
                guard let self else { return event }
                guard self.menuEnabledPIDs.contains(pid), let field = self.environment.windowField,
                      let owner = self.environment.windowOwner(UInt32(self.environment.integer(event,field))) else { return event }
                return owner == pid || owner == menuPID ? event : nil
            }
            return tap
        }
        entriesLock.withLock {
            guard let index = entries.firstIndex(where:{$0.pid == pid}) else { return }
            entries[index].menu = taps
            entries[index].suppressesMenu = true
        }
    }
    func stopMenu(pid: Int32) {
        entriesLock.withLock {
            guard let index = entries.firstIndex(where:{$0.pid == pid}) else { return }
            entries[index].menu = []; entries[index].suppressesMenu = false
        }
    }
    private func rawPID(_ event: Event) -> Int32? {
        environment.noticePIDField.map { Int32(environment.integer(event,$0)) }
    }
    private func release(_ event: Event) -> Bool {
        guard let field = environment.releaseTokenField else { return false }
        return environment.releaseFocus(UInt32(environment.integer(event,field)))
    }
    private func notice(_ event: Event) -> Event? {
        let target = Int32(environment.integer(event,40))
        let subtype = environment.noticeField.map { UInt16(environment.integer(event,$0)) }
        if subtype == 0x4000 {
            guard let raw = rawPID(event) else { return event }
            return stateLock.withLock {
                // Resolve the thief while the state lock is held.
                stored.taken(raw:raw,focus:environment.resolve(raw),victim:target,protected:protectedPIDs) ? nil : event
            }
        }
        if subtype == 0x8000 {
            return stateLock.withLock { stored.returned(to:target) ? nil : event }
        }
        guard target == bridgePID else { return event }
        if subtype == 2 {
            return stateLock.withLock {
                if let raw = rawPID(event) { return stored.newFront(raw:raw) ? nil : event }
                return stored.lastBridgeSuppression ? nil : event
            }
        }
        if subtype == 0xF102, let raw = rawPID(event) {
            // Unlike taken, resolve for focus-changed occurs outside the lock.
            let focus = environment.resolve(raw)
            stateLock.withLock {
                let previous = stored.current
                let snapshot = entriesLock.withLock { entries }
                let change = stored.changed(raw:raw,focus:focus,protected:snapshot.map(\.pid))
                // Queue one task for every matching entry, retaining the whole
                // entry (including taps) and without a later live/PID guard.
                for (entry, notification) in matching(snapshot, notifications:change.notifications) {
                    environment.enqueueCallback {
                        withExtendedLifetime(entry) {
                            switch notification { case .lost: entry.lost?(); case .gained: entry.gained?() }
                        }
                    }
                }
                var released = false
                if change.release { released = release(event) }
                else if change.inspectPreviousHost, let kind = environment.previousFocusedProcess(previous.app),
                        !protectedPIDs.contains(previous.app) {
                    switch kind {
                    case .application: released = release(event)
                    case .service: environment.repairHost(previous.app)
                    }
                }
                stored.completed(change,released:released)
            }
        }
        return event
    }
    private func matching(_ snapshot: [Entry], notifications: [ControllerKeyboardFocusState.Notification]) -> [(Entry, ControllerKeyboardFocusState.Notification)] {
        // Notifications preserve registration order and duplicate PID entries.
        // Pair by index rather than collapsing equal PIDs into a dictionary.
        var next = 0
        var result: [(Entry, ControllerKeyboardFocusState.Notification)] = []
        for entry in snapshot {
            guard next < notifications.count else { break }
            let notification = notifications[next]
            let pid: Int32
            switch notification { case .lost(let value), .gained(let value): pid = value }
            guard entry.pid == pid else { continue }
            result.append((entry,notification)); next += 1
        }
        return result
    }
}
