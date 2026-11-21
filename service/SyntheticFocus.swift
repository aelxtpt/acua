import AppKit
import ApplicationServices

// Session-owned receiver state. All tap installation/teardown is serialized on
// the main run loop; the callback only changes three booleans under a lock.
final class SyntheticFocusController {
    let pid: pid_t
    let processKey: String
    private let lock = NSLock()
    private var state: SyntheticFocusState
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var closed = false
    private var restoration: FocusRestoration?
    private var focusRegistration: UUID?

    init(pid: pid_t, processKey: String) throws {
        precondition(Thread.isMainThread)
        self.pid = pid; self.processKey = processKey
        state = SyntheticFocusState(believesActive: false, believesFocused: false, actuallyActive: false)
        do {
            focusRegistration = try FocusStealPreventer.register(pid: pid, processKey: processKey,
                lost: { [weak self] in
                    guard let self else { return }; self.lock.lock()
                    if !self.closed { self.state.believesFocused = false }; self.lock.unlock()
                }, gained: { [weak self] in
                    guard let self else { return }; self.lock.lock()
                    if !self.closed { self.state.believesFocused = true }; self.lock.unlock()
                })
        } catch { close(); throw error }
        let active = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        let focused = FocusStealPreventer.isFocused(pid)
        lock.withLock { state = SyntheticFocusState(believesActive: active, believesFocused: focused, actuallyActive: active) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<SyntheticFocusController>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                owner.lock.lock()
                if !owner.closed { owner.state.observe(type: type.rawValue, subtype: event.getIntegerValueField(CGEventField(rawValue: 83)!)) }
                owner.lock.unlock()
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = [UInt32(13), 19, 20].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        if let tap = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.tap = tap; self.source = source
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshActualState()
            }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier == self.pid else { return }
                self.close()
            }

    }

    private func refreshActualState() {
        let actual = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        lock.lock(); state.actuallyActive = actual; lock.unlock()
    }

    func enforce(window: AXUIElement?) throws {
        try RequestRuntime.check()
        guard let running = NSRunningApplication(processIdentifier: pid),
              AppResolver.processKey(running) == processKey else {
            throw ServiceError(.runningApplicationNotFound, "Focus target process changed")
        }
        let app = AXUIElementCreateApplication(pid)
        let frontmost = NSWorkspace.shared.frontmostApplication
        refreshActualState()
        lock.lock(); let current = state; let unavailable = closed; lock.unlock()
        guard !unavailable else { throw ServiceError(.noActiveSession, "Focus session ended") }
        let focused = AX.axElement(AX.copy(app, kAXFocusedWindowAttribute as String))
        let correctWindow = window.map { desired in focused.map { CFEqual($0, desired) } ?? false } ?? true
        let believesFrontmost = AX.copy(app, kAXFrontmostAttribute as String) as? Bool
        let packets: [CGEvent]
        if current.needsActivation || !correctWindow || believesFrontmost == false {
            packets = try activationPackets(window: window)
        } else if current.needsKeyFocusReturn {
            packets = try SyntheticFocusEvents.keyFocusReturned()
        } else { return }
        let send = { try self.send(packets) }
        let ready = {
            let active = AX.copy(app, kAXFrontmostAttribute as String) as? Bool
            let focus = AX.axElement(AX.copy(app, kAXFocusedWindowAttribute as String))
            let correct = window.map { desired in focus.map { CFEqual($0, desired) } ?? false } ?? true
            return active == true && correct
        }
        if let frontmost, frontmost.processIdentifier != pid {
            try FocusRestoration.serialized {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier else {
                    _ = AppSessions.shared.interrupt(pid: pid, process: processKey)
                    throw ServiceError(.userIntervened, "Foreground changed before synthetic activation")
                }
                let make = { try FocusRestoration(target: running, foreground: frontmost) }
                let transaction = try Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)
                lock.lock()
                guard !closed else { lock.unlock(); transaction.finish(); throw ServiceError(.noActiveSession, "Focus session ended") }
                restoration = transaction; lock.unlock()
                defer {
                    lock.lock(); if restoration === transaction { restoration = nil }; lock.unlock()
                    transaction.finish()
                }
                try transaction.perform(operation: send, ready: ready)
            }
            return
        }
        try send()
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .milliseconds(250))
        do {
            while true {
                try RequestRuntime.check()
                guard !running.isTerminated else { throw ServiceError(.runningApplicationNotFound, "Focus target exited") }
                let actual = NSWorkspace.shared.frontmostApplication
                if let frontmost, actual?.processIdentifier != frontmost.processIdentifier {
                    _ = AppSessions.shared.interrupt(pid: pid, process: processKey)
                    throw ServiceError(.userIntervened, "Foreground application changed during synthetic focus")
                }
                if ready() { return }
                guard clock.now < end else { throw ServiceError(.accessibilityError, "Synthetic focus did not become ready") }
                try RequestRuntime.wait(0.01)
            }
        } catch {
            // Do not leave an invented active state behind after a failed or
            // expired action. close() intentionally does not use request checks.
            close()
            throw error
        }
    }

    private func activationPackets(window: AXUIElement?) throws -> [CGEvent] {
        let id = try window.map(AccessibilityWindowSPI.windowID) ?? 0
        let frame = window.flatMap { win -> CGRect? in
            guard let p = AX.point(win, kAXPositionAttribute as String),
                  let s = AX.size(win, kAXSizeAttribute as String) else { return nil }
            return CGRect(origin: p, size: s)
        }
        return try SyntheticFocusEvents.activation(windowID: id, frame: frame,
                                                    activationPoint: window.flatMap { AX.point($0, "AXActivationPoint") })
    }

    private func send(_ packets: [CGEvent]) throws {
        try RequestRuntime.check()
        try lock.withLock {
            guard !closed else { throw ServiceError(.noActiveSession, "Focus session ended") }
            SyntheticFocusEvents.send(packets, to: pid)
            state.believesActive = true
            state.believesFocused = true
        }
    }

    func enforceForAccessibility(window: AXUIElement?) throws {
        try RequestRuntime.check()
        guard let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated, AppResolver.processKey(running) == processKey else { return }
        refreshActualState()
        let current = lock.withLock { state }
        guard !current.actuallyActive else { return }
        if current.needsActivation {
            let packets = try (try? activationPackets(window: window)) ?? SyntheticFocusEvents.activation()
            try send(packets)
        } else if current.needsKeyFocusReturn {
            try send(SyntheticFocusEvents.keyFocusReturned())
        }
    }

    func menuOpened(menuPID: pid_t?) {
        precondition(Thread.isMainThread)
        guard let focusRegistration else { return }
        FocusStealPreventer.suppressMenuDismissal(registration: focusRegistration, menuPID: menuPID)
    }

    func menuClosed() {
        precondition(Thread.isMainThread)
        guard let focusRegistration else { return }
        FocusStealPreventer.stopSuppressingMenuDismissal(registration: focusRegistration)
    }

    func close() {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.close() }; return }
        refreshActualState()
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; let deactivate = state.needsDeactivation
        let transaction = restoration; restoration = nil
        lock.unlock()
        transaction?.finish()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        activationObserver = nil
        terminationObserver = nil
        // Posting is asynchronous. Remove our activation tap first so its
        // invalidation cannot discard the deactivation queued behind it.
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
        if deactivate, let running = NSRunningApplication(processIdentifier: pid),
           AppResolver.processKey(running) == processKey,
           let events = try? SyntheticFocusEvents.deactivation() { SyntheticFocusEvents.send(events, to: pid) }
        // Deactivation sends while the enforcer still owns its registration;
        // deinit removes it.
        if let registration = focusRegistration { FocusStealPreventer.unregister(registration) }
        focusRegistration = nil
    }
    var clickFocused: Bool { lock.withLock { state.believesFocused } }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

enum SyntheticFocusSessions {
    private static let lock = NSLock()
    private static var controllers: [String: SyntheticFocusController] = [:]
    static func withTemporaryAccessibilityFocus<T>(app: ResolvedApp, window: AXUIElement?, operation: () -> T) -> T {
        let running = app.running
        guard !running.isActive, !running.isTerminated, !Permissions.screenLocked(),
              (try? RequestRuntime.check()) != nil else { return operation() }
        let key = AppResolver.processKey(running)
        let make = { try? SyntheticFocusController(pid: running.processIdentifier, processKey: key) }
        let controller = Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)
        defer { controller?.close() }
        try? controller?.enforceForAccessibility(window: window)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !running.isActive && !running.isTerminated && ContinuousClock.now < deadline {
            guard (try? RequestRuntime.wait(0.05)) != nil else { break }
        }
        return operation()
    }

    static func prepare(app: ResolvedApp) throws -> SyntheticFocusController {
        let bundle = app.bundleIdentifier, key = AppResolver.processKey(app.running)
        lock.lock(); let previous = controllers[bundle]; lock.unlock()
        let controller: SyntheticFocusController
        if let previous, previous.processKey == key, !previous.isClosed { controller = previous }
        else {
            previous?.close()
            let make = { try SyntheticFocusController(pid: app.running.processIdentifier, processKey: key) }
            controller = try Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)
            lock.lock(); controllers[bundle] = controller; lock.unlock()
        }
        return controller
    }
    static func enforce(app: ResolvedApp, window: AXUIElement?) throws {
        let controller = try prepare(app: app)
        do { try controller.enforce(window: window) }
        catch { controller.close(); throw error }
    }
    static func clickController(app: ResolvedApp) -> SyntheticFocusController? {
        let key = AppResolver.processKey(app.running)
        guard let value = controller(for: app.bundleIdentifier, processKey: key), !value.isClosed else { return nil }
        return value
    }
    static func menuOpened(bundle: String, processKey: String, menuPID: pid_t?) {
        controller(for: bundle, processKey: processKey)?.menuOpened(menuPID: menuPID)
    }
    static func menuClosed(bundle: String, processKey: String) {
        controller(for: bundle, processKey: processKey)?.menuClosed()
    }
    private static func controller(for bundle: String, processKey: String) -> SyntheticFocusController? {
        lock.withLock {
            guard let controller = controllers[bundle], controller.processKey == processKey else { return nil }
            return controller
        }
    }
    static func end(_ bundle: String) {
        lock.lock(); let controller = controllers.removeValue(forKey: bundle); lock.unlock()
        controller?.close()
    }
    static func endAll() {
        lock.lock(); let active = Array(controllers.values); controllers.removeAll(); lock.unlock()
        for controller in active { controller.close() }
    }
}
