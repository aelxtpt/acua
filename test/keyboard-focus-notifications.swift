import AppKit
import ApplicationServices

// Read-only evidence collector. Never suppresses/reposts events or releases
// focus. Only records notifications naming the disposable focus fixtures.
@main enum KeyboardFocusNotifications {
    static var allowed = Set<Int32>()
    static var records: [[String: Any]] = []
    static var includeAllNotifications = false
    static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let duration = min(300, max(1, Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60))
        includeAllNotifications = CommandLine.arguments.contains("--all-notifications")
        let update = {
            allowed = Set(NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier?.hasPrefix("test.acua.focus-fixture.") == true
            }.map(\.processIdentifier))
        }
        update()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in update() }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            guard type.rawValue == 21 else { return Unmanaged.passUnretained(event) }
            let receiver = event.getIntegerValueField(.eventTargetUnixProcessID)
            let focusPID = event.getIntegerValueField(CGEventField(rawValue: 73)!)
            guard KeyboardFocusNotifications.includeAllNotifications || Int32(exactly: receiver).map({ KeyboardFocusNotifications.allowed.contains($0) }) == true ||
                    Int32(exactly: focusPID).map({ KeyboardFocusNotifications.allowed.contains($0) }) == true else {
                return Unmanaged.passUnretained(event)
            }
            KeyboardFocusNotifications.records.append(["type": type.rawValue, "subtype64": event.getIntegerValueField(CGEventField(rawValue: 64)!),
                "receiver40": receiver, "source41": event.getIntegerValueField(.eventSourceUnixProcessID),
                "focus73": focusPID, "token71": event.getIntegerValueField(CGEventField(rawValue: 71)!)])
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1) << 21, callback: callback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fatalError("Could not install the read-only process-notification observer")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if let ready = CommandLine.arguments.first(where: { $0.hasPrefix("--ready-file=") }) {
            try Data("ready".utf8).write(to: URL(fileURLWithPath: String(ready.dropFirst("--ready-file=".count))))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        while ContinuousClock.now < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        timer.invalidate()
        CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        print(String(data: try JSONSerialization.data(withJSONObject: ["readOnly": true, "records": records], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
