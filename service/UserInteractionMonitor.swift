import AppKit
import CoreGraphics

/// A listen-only tap at the annotated-session/tail location.
/// The callback copies only event metadata; window lookup runs off the event tap.
final class UserInteractionMonitor {
    static let shared = UserInteractionMonitor()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let queue = DispatchQueue(label: "acua.user-interaction", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UUID?
    private let pid = getpid()

    func ensureRunning() throws {
        let started: Bool
        if Thread.isMainThread { started = start() }
        else { started = DispatchQueue.main.sync { self.start() } }
        guard started else {
            throw ServiceError(.permissionsNotGranted, "Could not observe user interaction; check Accessibility and Input Monitoring permissions")
        }
    }

    @discardableResult private func start() -> Bool {
        precondition(Thread.isMainThread)
        if let tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        stop()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<UserInteractionMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else { monitor.receive(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: UserInteraction.mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); return false
        }
        self.tap = tap; self.source = source
        lock.lock(); generation = UUID(); lock.unlock()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { stop(); return false }
        return true
    }

    private func stop() {
        precondition(Thread.isMainThread)
        lock.lock(); generation = nil; lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }

    private func receive(type: CGEventType, event: CGEvent) {
        // The event's window ID lives in CGEvent field 51.
        let window = CGEventField(rawValue: 51).map { event.getIntegerValueField($0) }
        let input = UserInteraction(type: type, sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            targetPID: event.getIntegerValueField(.eventTargetUnixProcessID), windowID: window)
        guard input.isExternal(to: pid) else { return }
        lock.lock(); let epoch = generation; lock.unlock()
        guard let epoch else { return }
        queue.async { [self] in process(input, epoch: epoch) }
    }

    private static func windowOwner(_ id: CGWindowID) -> Int32? {
        let window = WindowDescription.lookup(id)
        return (window?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    private func process(_ input: UserInteraction, epoch: UUID) {
        guard let target = input.target(windowOwner: Self.windowOwner),
              let application = NSRunningApplication(processIdentifier: target) else { return }
        let process = AppResolver.processKey(application)
        lock.lock()
        guard generation == epoch else { lock.unlock(); return }
        let bundles = AppSessions.shared.interrupt(pid: target, process: process)
        lock.unlock()
        if !bundles.isEmpty, ProcessInfo.processInfo.environment["ACUA_DIAGNOSTICS"] == "1" {
            // Metadata only: never record key contents, selected text or pixels.
            let detail = "Interaction interrupted session: type=\(input.type.rawValue) sourcePID=\(input.sourcePID) targetPID=\(target) windowID=\(input.windowID ?? -1) observedAt=\(Date().timeIntervalSince1970)\n"
            FileHandle.standardError.write(Data(detail.utf8))
        }
        // Hiding the cursor marshals to main. Never retain the monitor lock
        // across that hop: the main-thread tap callback also takes this lock.
        for bundle in bundles {
            AXMenuSessions.releaseAccessibility(bundle)
            SyntheticFocusSessions.end(bundle)
            Actions.hideCursor(for: bundle)
        }
    }
}
