import AppKit
import ApplicationServices

@main enum FocusPreventerNative {
    static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count == 5, let targetPID = Int32(args[1]), let foregroundPID = Int32(args[2]),
              let app = NSRunningApplication(processIdentifier: targetPID),
              let foreground = NSRunningApplication(processIdentifier: foregroundPID),
              [app, foreground].allSatisfy({ $0.bundleIdentifier?.hasPrefix("test.acua.focus-fixture.") == true }),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else { fatalError("Only selected focus fixtures are accepted") }
        let targetDirectory = URL(fileURLWithPath: args[3]), foregroundDirectory = URL(fileURLWithPath: args[4])
        var passed = 0, lost = [0,0], gained = [0,0]
        func fail(_ name: String) -> Never {
            let data = try! JSONSerialization.data(withJSONObject: ["failed": name, "diagnostics": FocusStealPreventer.diagnostics(), "keyboardPID": KeyboardFocusSPI.observe()?.resolvedPID ?? -1], options: [.sortedKeys])
            FileHandle.standardError.write(data + Data([10])); exit(1)
        }
        func check(_ name: String, _ valid: Bool) { if !valid { fail(name) }; passed += 1; FileHandle.standardOutput.write(Data("PASS \(name)\n".utf8)) }
        func wait(_ label: String, until predicate: () -> Bool) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !predicate() { if ContinuousClock.now >= deadline { fail(label) }; CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        }
        func events(_ directory: URL) -> [JSON] {
            guard let data = try? String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return [] }
            return data.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? JSON }
        }
        func command(_ value: String, _ directory: URL) throws { try value.write(to: directory.appendingPathComponent("command"), atomically: true, encoding: .utf8) }
        func state(_ directory: URL) throws -> JSON {
            let before = events(directory).count
            try command("state", directory)
            var observed: JSON?
            wait("fixture state") { observed = events(directory).dropFirst(before).first { $0["event"] as? String == "state" }; return observed != nil }
            return observed!
        }
        let targetBefore = try state(targetDirectory), foregroundBefore = try state(foregroundDirectory)
        let selection = foregroundBefore["selection"] as! [Int]
        let expectedForegroundText = (foregroundBefore["text"] as! NSString).replacingCharacters(
            in: NSRange(location: selection[0], length: selection[1]), with: "q")
        let key = AppResolver.processKey(app)
        let first = try FocusStealPreventer.register(pid: targetPID, processKey: key, lost: { lost[0] += 1 }, gained: { gained[0] += 1 })
        let second = try FocusStealPreventer.register(pid: targetPID, processKey: key, lost: { lost[1] += 1 }, gained: { gained[1] += 1 })
        defer { FocusStealPreventer.unregister(first); FocusStealPreventer.unregister(second); try? command("close-panel", targetDirectory) }
        let initial = FocusStealPreventer.diagnostics(), tapCount = initial["taps"] as! Int
        check("two registrations retain the shared global tap and per-PID filters", initial["registrations"] as? Int == 2 && tapCount >= 3)
        check("actual keyboard-focus owner is the foreground fixture", FocusStealPreventer.isFocused(foregroundPID))
        FocusStealPreventer.suppressMenuDismissal(registration: first, menuPID: nil)
        check("menu dismissal installs its temporary mouse filter", FocusStealPreventer.diagnostics()["taps"] as? Int == tapCount + 1)
        FocusStealPreventer.suppressMenuDismissal(registration: first, menuPID: foregroundPID)
        check("hosted menu replaces the filter with taps for both processes", FocusStealPreventer.diagnostics()["taps"] as? Int == tapCount + 2)
        FocusStealPreventer.stopSuppressingMenuDismissal(registration: first)
        FocusStealPreventer.stopSuppressingMenuDismissal(registration: first)
        check("menu dismissal cleanup is idempotent and preserves keyboard filters", FocusStealPreventer.diagnostics()["taps"] as? Int == tapCount)
        try command("nonactivating-panel", targetDirectory)
        wait("real panel theft with victim notification suppressed") { (FocusStealPreventer.diagnostics()["suppressedEvents"] as? Int ?? 0) >= 1 && KeyboardFocusSPI.observe()?.resolvedPID == targetPID }
        check("real nonactivating panel theft suppresses the victim notice", FocusStealPreventer.diagnostics()["suppressedEvents"] as? Int == 1)
        check("panel theft preserves actual foreground", NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID)
        // This ordinary panel sends changed/F102 to MenuBarAgent, not to the
        // ViewBridge receiver that the preventer guards. Actual release/callback
        // behavior for that other branch is not inferred from this scenario.
        check("ordinary panel does not invent a ViewBridge release", FocusStealPreventer.diagnostics()["releaseAttempts"] as? Int == 0 && lost == [0,0] && gained == [0,0])
        let foregroundEventCount = events(foregroundDirectory).count
        let targetEventCount = events(targetDirectory).count
        try command("foreign-key:\(targetPID)", targetDirectory)
        var foregroundAfter: JSON = [:]
        wait("foreign input rerouted to previous editor") {
            foregroundAfter = (try? state(foregroundDirectory)) ?? [:]
            return foregroundAfter["text"] as? String == expectedForegroundText
        }
        check("foreign keyboard is delivered to the victim editor", foregroundAfter["text"] as? String == expectedForegroundText)
        check("foreign keyboard is excluded from target editor", try state(targetDirectory)["text"] as? String == targetBefore["text"] as? String)
        // The filter also forwards flagsChanged (12), which macOS can emit
        // independently. Verify the injected key's delivery, not a global count.
        func injectedKeys(_ directory: URL, after count: Int) -> [JSON] {
            events(directory).dropFirst(count).filter {
                $0["event"] as? String == "input" && $0["keyCode"] as? Int == 12 &&
                [10, 11].contains($0["type"] as? Int ?? -1)
            }
        }
        wait("rerouted key down and key up delivered") {
            injectedKeys(foregroundDirectory, after: foregroundEventCount).count >= 2
        }
        check("both key down and key up were rerouted",
              injectedKeys(foregroundDirectory, after: foregroundEventCount).compactMap { $0["type"] as? Int } == [10, 11] &&
              injectedKeys(targetDirectory, after: targetEventCount).isEmpty &&
              (FocusStealPreventer.diagnostics()["redirectedKeys"] as? Int ?? 0) >= 2)
        try command("close-panel", targetDirectory)
        wait("panel closed") { events(targetDirectory).last { $0["event"] as? String == "panel-closed" } != nil }
        wait("native panel returns real keyboard focus") { KeyboardFocusSPI.observe()?.resolvedPID == foregroundPID && (FocusStealPreventer.diagnostics()["suppressedEvents"] as? Int ?? 0) >= 2 }
        check("the victim return notification is suppressed once", FocusStealPreventer.diagnostics()["suppressedEvents"] as? Int == 2)
        FocusStealPreventer.unregister(first)
        check("removing one registration preserves remaining filters", FocusStealPreventer.registrationCount == 1 && FocusStealPreventer.diagnostics()["taps"] as? Int == tapCount - 1)
        try command("nonactivating-panel", targetDirectory)
        wait("remaining registration protects next theft") { (FocusStealPreventer.diagnostics()["suppressedEvents"] as? Int ?? 0) >= 3 && KeyboardFocusSPI.observe()?.resolvedPID == targetPID }
        check("remaining registration protects a second real panel theft", FocusStealPreventer.diagnostics()["suppressedEvents"] as? Int == 3)
        let closeCount = events(targetDirectory).filter { $0["event"] as? String == "panel-closed" }.count
        try command("close-panel", targetDirectory)
        wait("second panel returns focus") { events(targetDirectory).filter { $0["event"] as? String == "panel-closed" }.count > closeCount && KeyboardFocusSPI.observe()?.resolvedPID == foregroundPID }
        let final = FocusStealPreventer.diagnostics()
        FocusStealPreventer.unregister(second)
        check("last registration removes all persistent resources", FocusStealPreventer.registrationCount == 0 && FocusStealPreventer.diagnostics()["taps"] as? Int == 0)
        check("host parser preserves Unicode and removes trailing closing parentheses", KeyboardFocusResolver.hostName("Service (Aplicativo 🙂))") == "Aplicativo 🙂")
        check("host parser takes the innermost name from nested delimiters", KeyboardFocusResolver.hostName("Service (outer (Inner))") == "Inner")
        check("host parser rejects a name without delimiters", KeyboardFocusResolver.hostName("Regular App") == nil)
        check("host parser excludes the last nonclosing character from delimiter search", KeyboardFocusResolver.hostName("Service (Host) (") == "Host) (")
        print(String(data: try JSONSerialization.data(withJSONObject: ["checks": passed, "final": final], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
