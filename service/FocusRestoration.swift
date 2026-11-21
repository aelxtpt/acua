import AppKit
import ApplicationServices

// Owns the temporary foreign-foreground transaction. Taps
// perform metadata-only decisions; AX reads, restoration and polling run outside
// their callbacks. finish() is idempotent and also usable by Stop/shutdown.
final class FocusRestoration {
    private let lock = NSLock()
    private var policy = FocusRestorationPolicy(now: ProcessInfo.processInfo.systemUptime)
    private var finished = false
    private var taps: [(CFMachPort, CFRunLoopSource)] = []
    private final class TapContext {
        unowned let owner: FocusRestoration
        let foreground: Bool
        init(_ owner: FocusRestoration, _ foreground: Bool) { self.owner = owner; self.foreground = foreground }
    }
    private var contexts: [TapContext] = []
    private var updates: WindowServerUpdates.Lease?
    let target: NSRunningApplication
    let foreground: NSRunningApplication
    private let targetKey: String
    private let foregroundKey: String
    private let previousWindow: AXUIElement?
    private let previousWindowID: UInt32?
    private let servicePID = getpid()
    private static let gate = DispatchSemaphore(value: 1)

    init(target: NSRunningApplication, foreground: NSRunningApplication) throws {
        precondition(Thread.isMainThread)
        self.target = target; self.foreground = foreground
        targetKey = AppResolver.processKey(target); foregroundKey = AppResolver.processKey(foreground)
        let previousApp = AXUIElementCreateApplication(foreground.processIdentifier)
        previousWindow = AX.axElement(AX.copy(previousApp, kAXFocusedWindowAttribute as String))
        previousWindowID = previousWindow.flatMap { try? AccessibilityWindowSPI.windowID($0) }
        do {
            try install(pid: foreground.processIdentifier, foreground: true)
            try install(pid: target.processIdentifier, foreground: false)
            updates = try WindowServerUpdates.pause()
        } catch { finish(); throw error }
    }

    private func install(pid: pid_t, foreground: Bool) throws {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tapContext = Unmanaged<TapContext>.fromOpaque(context).takeUnretainedValue()
            let scope = tapContext.owner
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                for (tap, _) in scope.taps { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return scope.filter(type: type, event: event, foregroundTap: tapContext.foreground)
        }
        let activation = [UInt32(13), 19, 20]
        let types = foreground ? activation : activation + [10, 11, 12]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let context = TapContext(self, foreground)
        guard let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            throw ServiceError(.permissionsNotGranted, "Could not install focus restoration event filter")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ServiceError(.accessibilityError, "Could not create focus restoration event source")
        }
        taps.append((tap, source))
        contexts.append(context)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func filter(type: CGEventType, event: CGEvent, foregroundTap: Bool) -> Unmanaged<CGEvent>? {
        let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        lock.lock()
        if finished { lock.unlock(); return Unmanaged.passUnretained(event) }
        if !foregroundTap && FocusRestorationPolicy.redirect(type: type.rawValue, sourcePID: sourcePID, targetPID: targetPID,
                                           servicePID: servicePID, receiverPID: target.processIdentifier) {
            lock.unlock()
            event.postToPid(foreground.processIdentifier)
            return nil
        }
        let subtype = event.getIntegerValueField(CGEventField(rawValue: 83)!)
        let now = ProcessInfo.processInfo.systemUptime
        let drop: Bool
        if foregroundTap {
            drop = policy.suppressForeground(type: type.rawValue, subtype: subtype, now: now)
        } else { drop = policy.suppressTarget(type: type.rawValue, subtype: subtype, now: now) }
        lock.unlock()
        return drop ? nil : Unmanaged.passUnretained(event)
    }

    static func serialized<T>(_ body: () throws -> T) throws -> T {
        while gate.wait(timeout: .now() + 0.01) != .success { try RequestRuntime.check() }
        defer { gate.signal() }
        try RequestRuntime.check()
        return try body()
    }

    func perform(operation: () throws -> Void, ready: () throws -> Bool) throws {
        defer { finish() }
        var operationError: Error?
        do { try operation() } catch { operationError = error }
        let clock = ContinuousClock(), start = ContinuousClock.now
        var restored = false
        var lastRestore = -Double.infinity
        while true {
            try RequestRuntime.check()
            lock.lock(); let ended = finished; lock.unlock()
            guard !ended else { throw ServiceError(.noActiveSession, "Focus restoration ended") }
            guard !target.isTerminated, AppResolver.processKey(target) == targetKey else {
                throw ServiceError(.runningApplicationNotFound, "Focus target exited or changed")
            }
            guard !foreground.isTerminated, AppResolver.processKey(foreground) == foregroundKey else {
                throw ServiceError(.accessibilityError, "Previous foreground process exited or changed")
            }
            let elapsed = start.duration(to: clock.now)
            guard elapsed < .seconds(2) else { throw ServiceError(.accessibilityError, "Focus restoration timed out") }
            let now = ProcessInfo.processInfo.systemUptime
            let actual = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if actual == target.processIdentifier {
                if now - lastRestore >= 0.05 {
                    lock.lock(); policy.beginForegroundRestore(now: now); lock.unlock()
                    guard foreground.activate(options: []) else {
                        throw ServiceError(.accessibilityError, "Could not restore the previous foreground app")
                    }
                    restored = true; lastRestore = now
                }
            } else if actual != foreground.processIdentifier {
                _ = AppSessions.shared.interrupt(pid: target.processIdentifier, process: targetKey)
                throw ServiceError(.userIntervened, "A different application became foreground during focus restoration")
            } else {
                if try restoreWindowOrder() { lock.lock(); policy.windowRaised(now: now); lock.unlock() }
                let receiverReady = try operationError != nil || ready()
                lock.lock(); let quiet = policy.ready(now: now, restoredForeground: restored, hasError: operationError != nil); lock.unlock()
                if receiverReady && quiet {
                    if let operationError { throw operationError }
                    return
                }
            }
            if Thread.isMainThread { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
            else { try RequestRuntime.wait(0.01) }
        }
    }

    private func restoreWindowOrder() throws -> Bool {
        guard let previousWindow, let previousWindowID else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let index = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == previousWindowID }),
              let level = windows[index][kCGWindowLayer as String] as? NSNumber,
              windows[..<index].contains(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? NSNumber) == level
              }) else { return false }
        let error = AXUIElementPerformAction(previousWindow, kAXRaiseAction as CFString)
        guard error == .success else { throw ServiceError(.accessibilityError, "Could not restore previous foreground window ordering") }
        return true
    }

    func finish() {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.finish() }; return }
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let paused = updates; updates = nil
        lock.unlock()
        // On failure/cancellation, restore only our displaced foreground app;
        // never override an unrelated foreground change made by the user.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
           !foreground.isTerminated, AppResolver.processKey(foreground) == foregroundKey {
            _ = foreground.activate(options: [])
        }
        // Reenable updates before removing the temporary taps.
        paused?.finish()
        for (tap, source) in taps {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap)
        }
        taps.removeAll()
        contexts.removeAll()
        // If a third app won focus, the old foreground receiver must not keep
        // the active appearance whose deactivation packets we just suppressed.
        let actual = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let actual, actual != foreground.processIdentifier, actual != target.processIdentifier,
           !foreground.isTerminated, AppResolver.processKey(foreground) == foregroundKey,
           let events = try? SyntheticFocusEvents.deactivation() {
            SyntheticFocusEvents.send(events, to: foreground.processIdentifier)
        }
    }
}
