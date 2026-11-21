import AppKit
import ApplicationServices

@main enum PairGate {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let state = ScreenLockState.read()
        let ax = AXIsProcessTrusted(), sr = CGPreflightScreenCaptureAccess()
        var output: [String: Any] = ["ready": state.interactionAvailable && ax && sr,
            "screenLocked": state.state == .unavailable ? NSNull():state.state == .locked,
            "screenInteractionAvailable": state.interactionAvailable, "screenLockState": state.state.rawValue,
            "screenLockSource": state.source.rawValue, "screenLockReason": state.reason,
            "onConsole": state.onConsole as Any? ?? NSNull(),
            "accessibility": ax, "screenRecording": sr, "physicalInputPosted": false]
        if args.count == 2 && args[1] == "check" {
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), as: UTF8.self))
            return
        }
        guard args.count == 4, args[1] == "cleanup", let pid = Int32(args[2]), pid > 1,
              let until = Double(args[3]), until.isFinite, until > Date().timeIntervalSince1970,
              until - Date().timeIntervalSince1970 <= 180,
              let app = NSRunningApplication(processIdentifier: pid),
              ["test.acua.rust-fixture", "test.acua.coordinate-fixture"].contains(app.bundleIdentifier ?? "") else {
            output["error"] = "A current authorization deadline and a live owned fixture are required"
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), as: UTF8.self))
            exit(2)
        }
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let keys: [CGKeyCode] = [0, 55] // Only A and Command, used by this probe.
        let held = keys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }
        output["residualLeftButton"] = left; output["residualKeys"] = held
        var posted = 0
        if left, let position = CGEvent(source: nil)?.location,
           let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left) {
            event.post(tap: .cghidEventTap); posted += 1
        }
        for key in held {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) {
                event.post(tap: .cghidEventTap); posted += 1
            }
        }
        output["physicalInputPosted"] = posted > 0; output["cleanupEventsPosted"] = posted
        output["inputWasReleasedByService"] = !left && held.isEmpty
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), as: UTF8.self))
    }
}
