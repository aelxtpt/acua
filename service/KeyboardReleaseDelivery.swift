import AppKit
import ApplicationServices

// A short-lived, listen-only tail observer. Cleanup waits for its releases to
// pass existing PID filters before a concurrent Stop invalidates those filters
// or deactivates the receiver. It never rewrites or suppresses input.
final class KeyboardReleaseDelivery {
    private let condition = NSCondition()
    private var pending = Set<UInt64>()
    private var lastTimestamp: UInt64 = 0
    private var closed = false
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    init(pid: Int32) throws {
        let install = {
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<KeyboardReleaseDelivery>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = owner.port { CGEvent.tapEnable(tap: port, enable: true) }
                } else {
                    owner.condition.lock()
                    owner.pending.remove(event.timestamp)
                    owner.condition.broadcast()
                    owner.condition.unlock()
                }
                return Unmanaged.passUnretained(event)
            }
            let mask = (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            guard let port = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw ServiceError(.permissionsNotGranted, "Could not observe keyboard release delivery")
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                throw ServiceError(.accessibilityError, "Could not create keyboard release observer")
            }
            self.port = port; self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }
        if Thread.isMainThread { try install() } else { try DispatchQueue.main.sync(execute: install) }
    }

    func willPost(_ event: CGEvent) {
        condition.lock()
        let timestamp = max(DispatchTime.now().uptimeNanoseconds, lastTimestamp + 1)
        lastTimestamp = timestamp
        event.timestamp = timestamp
        pending.insert(timestamp)
        condition.unlock()
    }

    func waitUntilDelivered() -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(500)
        condition.lock()
        while !pending.isEmpty {
            guard ContinuousClock.now < deadline else { condition.unlock(); return false }
            if Thread.isMainThread {
                condition.unlock()
                CFRunLoopRunInMode(.defaultMode, 0.005, false)
                condition.lock()
            } else {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.005))
            }
        }
        condition.unlock()
        return true
    }

    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        condition.unlock()
        let remove = {
            if let source = self.source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let port = self.port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
            self.source = nil; self.port = nil
        }
        if Thread.isMainThread { remove() } else { DispatchQueue.main.sync(execute: remove) }
    }

    deinit { close() }
}
