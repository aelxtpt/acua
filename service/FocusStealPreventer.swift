import AppKit
import ApplicationServices
import OSLog

// Persistent filters, separate from the temporary foreground restoration.
// Installation and invalidation run on main; no client callback runs under a
// state lock. The global tap and per-PID keyboard taps are default,
// not listen-only, because their return value can suppress an event.
final class FocusStealPreventer {
    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "FocusStealPreventer")
    private final class TapContext {
        unowned let owner: FocusStealPreventer
        let menuOwner: Int32?
        let menuPID: Int32?
        let global: Bool
        init(_ owner: FocusStealPreventer, global: Bool = false, menuOwner: Int32? = nil, menuPID: Int32? = nil) {
            self.owner = owner; self.global = global; self.menuOwner = menuOwner; self.menuPID = menuPID
        }
    }
    private final class Tap {
        let port: CFMachPort
        let source: CFRunLoopSource?
        let context: TapContext
        init(_ port: CFMachPort, _ source: CFRunLoopSource?, _ context: TapContext) {
            self.port = port; self.source = source; self.context = context
        }
        func close() {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port)
        }
    }
    private struct Entry {
        let id: UUID
        let pid: Int32
        let processKey: String
        let lost: () -> Void
        let gained: () -> Void
        let keyboard: Tap?
        var menu: [Tap] = []
    }
    private static let registryLock = NSLock()
    private static var shared: FocusStealPreventer?
    private let lock = NSLock()
    private var state: SystemKeyboardFocusState
    private var entries: [Entry] = []
    private var global: Tap?
    private var bridgeKeyboard: Tap?
    private let bridgePID: Int32?
    private let servicePID = getpid()
    private var closed = false
    private(set) var releaseAttempts = 0
    private(set) var releaseSuccesses = 0
    private(set) var suppressedEvents = 0
    private(set) var redirectedKeys = 0

    private init() throws {
        precondition(Thread.isMainThread)
        state = SystemKeyboardFocusState(focus: KeyboardFocusResolver.current())
        bridgePID = KeyboardFocusResolver.viewBridgePID()
        do {
            global = try install(pid: nil, types: [21], place: .tailAppendEventTap, context: TapContext(self, global: true))
            if let bridgePID { bridgeKeyboard = try keyboardTap(pid: bridgePID) }
        } catch { finish(); throw error }
    }
    static func register(pid: Int32, processKey: String, lost: @escaping () -> Void, gained: @escaping () -> Void) throws -> UUID {
        precondition(Thread.isMainThread)
        registryLock.lock(); let previous = shared; registryLock.unlock()
        let instance = try previous ?? FocusStealPreventer()
        do {
            let tap = try instance.keyboardTap(pid: pid), id = UUID()
            instance.lock.lock()
            instance.entries.append(Entry(id: id, pid: pid, processKey: processKey, lost: lost, gained: gained, keyboard: tap))
            instance.lock.unlock()
            registryLock.lock(); shared = instance; registryLock.unlock()
            return id
        } catch { if previous == nil { instance.finish() }; throw error }
    }
    static func unregister(_ id: UUID) {
        precondition(Thread.isMainThread)
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return }
        instance.lock.lock()
        let index = instance.entries.firstIndex { $0.id == id }
        let removed = index.map { instance.entries.remove(at: $0) }
        let empty = instance.entries.isEmpty
        instance.lock.unlock()
        removed?.keyboard?.close(); removed?.menu.forEach { $0.close() }
        if empty {
            registryLock.lock(); if shared === instance { shared = nil }; registryLock.unlock()
            instance.finish()
        }
    }
    static func isFocused(_ pid: Int32) -> Bool {
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return KeyboardFocusResolver.current().appPID == pid }
        instance.lock.lock(); defer { instance.lock.unlock() }
        return instance.state.currentFocus.appPID == pid
    }
    private func keyboardTap(pid: Int32) throws -> Tap? {
        try install(pid: pid, types: [10, 11, 12], place: .tailAppendEventTap, context: TapContext(self))
    }
    private func install(pid: Int32?, types: [UInt32], place: CGEventTapPlacement, context: TapContext) throws -> Tap? {
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<TapContext>.fromOpaque(pointer).takeUnretainedValue()
            let owner = context.owner
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.reenable(); return Unmanaged.passUnretained(event)
            }
            return owner.filter(type: type, event: event, context: context)
        }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let port: CFMachPort?
        if let pid { port = CGEvent.tapCreateForPid(pid: pid, place: place, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: pointer) }
        else { port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: place, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: pointer) }
        // EventTap.startMonitoring retains the logical
        // observer when tap creation fails; other filters still get a turn.
        guard let port else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: true)
        return Tap(port, source, context)
    }
    private func reenable() {
        lock.lock(); let taps = [global, bridgeKeyboard].compactMap { $0 } + entries.flatMap { [$0.keyboard].compactMap { $0 } + $0.menu }; let ended = closed; lock.unlock()
        if !ended { for tap in taps { CGEvent.tapEnable(tap: tap.port, enable: true) } }
    }
    private func liveEntries() -> [Entry] {
        entries.filter { entry in
            guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return false }
            return AppResolver.processKey(app) == entry.processKey
        }
    }
    private func filter(type: CGEventType, event: CGEvent, context: TapContext) -> Unmanaged<CGEvent>? {
        let receiver = event.getIntegerValueField(.eventTargetUnixProcessID)
        let source = event.getIntegerValueField(.eventSourceUnixProcessID)
        if let menuOwner = context.menuOwner {
            let id = event.getIntegerValueField(CGEventField(rawValue: 51)!)
            guard let number = UInt32(exactly: id), number != 0 else { return Unmanaged.passUnretained(event) }
            lock.lock(); let enabled = !closed && liveEntries().contains { $0.pid == menuOwner && !$0.menu.isEmpty }; lock.unlock()
            guard enabled, let window = WindowDescription.lookup(number),
                  let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != menuOwner, owner != context.menuPID else { return Unmanaged.passUnretained(event) }
            lock.lock(); suppressedEvents += 1; lock.unlock(); return nil
        }
        if !context.global {
            lock.lock(); let recipient = closed ? nil : state.keyboardRecipient(sourcePID: source, targetPID: receiver, servicePID: servicePID)
            if recipient != nil { redirectedKeys += 1 }; lock.unlock()
            if let recipient { event.postToPid(recipient); return nil }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 21, let recipient = Int32(exactly: receiver) else { return Unmanaged.passUnretained(event) }
        let subtype = event.getIntegerValueField(CGEventField(rawValue: 64)!)
        let raw = Int32(exactly: event.getIntegerValueField(CGEventField(rawValue: 73)!))
        if subtype == 0x4000, let raw {
            let focus = KeyboardFocusResolver.resolve(raw)
            lock.lock(); let drop = !closed && state.keyFocusTaken(thiefPID: raw, thief: focus, victimPID: recipient, protectedApps: liveEntries().map(\.pid))
            if drop { suppressedEvents += 1 }; lock.unlock()
            return drop ? nil : Unmanaged.passUnretained(event)
        }
        lock.lock()
        if closed { lock.unlock(); return Unmanaged.passUnretained(event) }
        if subtype == 0x8000 {
            let drop = state.keyFocusReturned(to: recipient); if drop { suppressedEvents += 1 }; lock.unlock()
            return drop ? nil : Unmanaged.passUnretained(event)
        }
        guard recipient == bridgePID else { lock.unlock(); return Unmanaged.passUnretained(event) }
        if subtype == 2, let raw {
            let drop = state.newFront(focusPID: raw); if drop { suppressedEvents += 1 }; lock.unlock()
            return drop ? nil : Unmanaged.passUnretained(event)
        }
        lock.unlock()
        if subtype == 0xF102, let raw {
            let focus = KeyboardFocusResolver.resolve(raw)
            lock.lock()
            let entries = liveEntries(), previousAppPID = state.currentFocus.appPID
            let change = state.focusChanged(to: focus, rawPID: raw, protectedApps: entries.map(\.pid))
            lock.unlock()
            var delivered = Set<UUID>()
            for notification in change.notifications {
                let pid: Int32
                switch notification { case .lost(let value), .gained(let value): pid = value }
                guard let entry = entries.first(where: { $0.pid == pid && !delivered.contains($0.id) }) else { continue }
                delivered.insert(entry.id)
                let callback: () -> Void
                switch notification { case .lost: callback = entry.lost; case .gained: callback = entry.gained }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let live = !self.closed && self.liveEntries().contains { $0.id == entry.id }; self.lock.unlock()
                    if live { callback() }
                }
            }
            // Queue lost/gained callbacks before any token release
            // or hosted repair, then records the actual release result.
            let released = HostedFocusRepair.perform(releaseTheft: change.releaseTheft,
                inspectViewService: change.inspectViewService, previousAppPID: previousAppPID,
                previousAppProtected: entries.contains { $0.pid == previousAppPID },
                focusedProcess: { KeyboardFocusResolver.focusedProcessKind(in: previousAppPID) },
                release: { self.releaseFocus(from: event) }, repair: { pid in
                    Task.detached {
                        do { try SyntheticFocusEvents.repairHostedFocus(to: pid) }
                        catch { Self.logger.error("Could not repair hosted focus for PID \(pid): \(String(describing: error), privacy: .public)") }
                    }
                })
            lock.lock(); state.completed(change, releasedFocus: released); lock.unlock()
        }
        return Unmanaged.passUnretained(event)
    }

    private func releaseFocus(from event: CGEvent) -> Bool {
        guard let token = UInt32(exactly: event.getIntegerValueField(CGEventField(rawValue: 71)!)) else { return false }
        let released = KeyboardFocusSPI.releaseFocus(token: token)
        lock.lock(); releaseAttempts += 1; if released { releaseSuccesses += 1 }; lock.unlock()
        return released
    }
    static func suppressMenuDismissal(registration: UUID, menuPID: Int32?) {
        precondition(Thread.isMainThread)
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return }
        instance.lock.lock(); let entry = instance.entries.first { $0.id == registration }; instance.lock.unlock()
        guard let entry else { return }
        let taps = [entry.pid, menuPID].compactMap { $0 }.compactMap { pid -> Tap? in
            do {
                return try instance.install(pid: pid, types: [1,2,6,3,4,7,25,26,27], place: .headInsertEventTap,
                    context: TapContext(instance, menuOwner: entry.pid, menuPID: menuPID))
            } catch {
                logger.error("Could not install menu dismissal filter for PID \(pid): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        instance.lock.lock(); let index = instance.entries.firstIndex { $0.id == registration }
        let previous = index.map { instance.entries[$0].menu } ?? []
        if let index { instance.entries[index].menu = taps }; instance.lock.unlock()
        previous.forEach { $0.close() }; if index == nil { taps.forEach { $0.close() } }
    }
    static func stopSuppressingMenuDismissal(registration: UUID) {
        precondition(Thread.isMainThread)
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return }
        instance.lock.lock(); let index = instance.entries.firstIndex { $0.id == registration }
        let taps = index.map { instance.entries[$0].menu } ?? []
        if let index { instance.entries[index].menu = [] }; instance.lock.unlock()
        taps.forEach { $0.close() }
    }
    private func finish() {
        precondition(Thread.isMainThread)
        lock.lock(); if closed { lock.unlock(); return }; closed = true
        let taps = [global, bridgeKeyboard].compactMap { $0 } + entries.flatMap { [$0.keyboard].compactMap { $0 } + $0.menu }
        global = nil; bridgeKeyboard = nil; entries = []; lock.unlock()
        taps.forEach { $0.close() }
    }
    static var registrationCount: Int {
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return 0 }; instance.lock.lock(); defer { instance.lock.unlock() }; return instance.entries.count
    }
    static func hasKeyboardFilter(for pid: Int32) -> Bool {
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return false }
        instance.lock.lock(); defer { instance.lock.unlock() }
        return !instance.closed && instance.entries.contains { $0.pid == pid && $0.keyboard?.source != nil }
    }
    static func diagnostics() -> JSON {
        registryLock.lock(); let instance = shared; registryLock.unlock()
        guard let instance else { return ["registrations": 0, "taps": 0] }
        instance.lock.lock(); defer { instance.lock.unlock() }
        return ["registrations": instance.entries.count,
            "taps": (instance.global == nil ? 0 : 1) + (instance.bridgeKeyboard == nil ? 0 : 1) + instance.entries.reduce(0) { $0 + ($1.keyboard == nil ? 0 : 1) + $1.menu.count },
            "bridgePID": instance.bridgePID ?? -1, "focusPID": instance.state.currentFocus.appPID,
            "releaseAttempts": instance.releaseAttempts, "releaseSuccesses": instance.releaseSuccesses,
            "suppressedEvents": instance.suppressedEvents, "redirectedKeys": instance.redirectedKeys]
    }
}
