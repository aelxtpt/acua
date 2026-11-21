import AppKit
import ApplicationServices

@main enum HostedFocusRepairPackets {
    private final class Capture { var events: [CGEvent] = [] }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let capture = Capture()
        let callback: CGEventTapCallBack = { _, type, event, context in
            if type.rawValue == 21, let context {
                let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
                if event.getIntegerValueField(.eventSourceUnixProcessID) == getpid(), let copy = event.copy() {
                    capture.events.append(copy)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreateForPid(pid: getpid(), place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1) << 21, callback: callback,
            userInfo: Unmanaged.passUnretained(capture).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw ServiceError(.permissionsNotGranted, "Owned repair-packet observer unavailable")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        defer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        // Sends only process notices to this windowless test process. It does
        // not call CPSReleaseKeyFocusWithID or post events to any other PID.
        try SyntheticFocusEvents.repairHostedFocus(to: getpid())
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while capture.events.count < 2 && ContinuousClock.now < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        let events = capture.events
        func check(_ name: String, _ valid: Bool) { precondition(valid, name); print("PASS \(name)") }
        check("repair posts exactly two native process notices to its owned receiver", events.count == 2)
        let subtype = CGEventField(rawValue: 64)!
        check("repair preserves taken-then-returned order", events.map { $0.getIntegerValueField(subtype) } == [0x4000, 0x8000])
        check("repair packets carry fresh monotonic timestamps", events.allSatisfy { $0.timestamp >= start } && events[1].timestamp >= events[0].timestamp)
        check("repair packets remain process notices without input flags", events.allSatisfy { $0.type.rawValue == 21 && $0.flags.isEmpty })
        check("repair delivery is addressed exclusively to the owned process", events.allSatisfy { $0.getIntegerValueField(.eventTargetUnixProcessID) == getpid() })
        check("repair does not activate its prohibited receiver", !app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
    }
}
