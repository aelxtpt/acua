import AppKit
import ApplicationServices
import Darwin

private final class ResultBox {
    let lock = NSLock()
    var result: JSON?
    func set(_ value: JSON) { lock.lock(); result = value; lock.unlock() }
    func get() -> JSON? { lock.lock(); defer { lock.unlock() }; return result }
}

@main enum FocusRestorationNative {
    enum Fault: Error { case operation }
    nonisolated static func orderRestored(targetID: UInt32?, previousID: UInt32?) -> Bool {
        guard let targetID, let previousID else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let ids = windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        guard let a = ids.firstIndex(of: previousID), let b = ids.firstIndex(of: targetID) else { return false }
        return a < b
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        guard args.count >= 5, let targetPID = Int32(args[2]), let foregroundPID = Int32(args[3]),
              let target = NSRunningApplication(processIdentifier: targetPID),
              let foreground = NSRunningApplication(processIdentifier: foregroundPID),
              [target, foreground].allSatisfy({ $0.bundleIdentifier?.hasPrefix("test.acua.focus-fixture.") == true }),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else {
            fatalError("Only two explicitly selected disposable focus fixtures are accepted")
        }
        let mode = args[1], directory = URL(fileURLWithPath: args[4]), box = ResultBox()
        let axTarget = AXUIElementCreateApplication(targetPID), axForeground = AXUIElementCreateApplication(foregroundPID)
        let candidates = AX.copy(axTarget, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let targetWindow = candidates.first { AX.string($0, kAXTitleAttribute as String) == "CUA input target" }
        let previousWindow = AX.axElement(AX.copy(axForeground, kAXFocusedWindowAttribute as String))
        let targetID = try targetWindow.map(AccessibilityWindowSPI.windowID)
        let previousID = try previousWindow.map(AccessibilityWindowSPI.windowID)
        guard targetID != nil, previousID != nil else { fatalError("Both fixture window IDs must be observed") }
        let transaction = try FocusRestoration(target: target, foreground: foreground)
        DispatchQueue.global().async {
            var outcome: JSON = ["mode": mode, "leasesDuringOperation": 0]
            do {
                let milliseconds = mode == "deadline" ? 20.0 : 5000.0
                try RequestRuntime.withRequest(["deadlineUnixMilliseconds": Date().timeIntervalSince1970 * 1000 + milliseconds]) {
                    try transaction.perform(operation: {
                        outcome["leasesDuringOperation"] = WindowServerUpdates.activeLeaseCount
                        target.activate(options: [])
                        let end = ContinuousClock.now.advanced(by: .seconds(1))
                        while NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
                            guard ContinuousClock.now < end else { throw ServiceError(.accessibilityError, "Fixture did not become foreground") }
                            try RequestRuntime.wait(0.01)
                        }
                        outcome["targetReallyBecameForeground"] = true
                        if mode == "operation-error" { throw Fault.operation }
                        if mode == "deadline" { try RequestRuntime.wait(0.1) }
                        if mode == "foreign-key" {
                            try "foreign-key:\(targetPID)".write(to: directory.appendingPathComponent("command"), atomically: true, encoding: .utf8)
                            try RequestRuntime.wait(0.1)
                        }
                        if mode == "target-exit" { _ = kill(targetPID, SIGTERM); try RequestRuntime.wait(0.05) }
                        if mode == "third-app" {
                            guard args.count > 5, let thirdPID = Int32(args[5]), let third = NSRunningApplication(processIdentifier: thirdPID),
                                  third.bundleIdentifier?.hasPrefix("test.acua.focus-fixture.") == true else { throw Fault.operation }
                            third.activate(options: [])
                            try RequestRuntime.wait(0.1)
                        }
                        if mode == "window-order" {
                            foreground.activate(options: [])
                            let end = ContinuousClock.now.advanced(by: .seconds(1))
                            while NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundPID {
                                guard ContinuousClock.now < end else { throw Fault.operation }
                                try RequestRuntime.wait(0.01)
                            }
                            guard args.count > 6 else { throw Fault.operation }
                            try "raise-window".write(to: URL(fileURLWithPath: args[6]).appendingPathComponent("command"), atomically: true, encoding: .utf8)
                            let orderDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                            while Self.orderRestored(targetID: targetID, previousID: previousID) && ContinuousClock.now < orderDeadline { try RequestRuntime.wait(0.01) }
                            outcome["orderWasDisplaced"] = !Self.orderRestored(targetID: targetID, previousID: previousID)
                        }
                    }, ready: { (AX.copy(axTarget, kAXFrontmostAttribute as String) as? Bool) == true })
                }
                outcome["success"] = true
            } catch Fault.operation { outcome["error"] = "operationFault" }
            catch let error as ServiceError { outcome["errorCode"] = error.code.rawValue; outcome["errorMessage"] = error.message }
            catch { outcome["error"] = String(describing: error) }
            outcome["leasesAfterCompletion"] = WindowServerUpdates.activeLeaseCount
            outcome["actualFrontmostPID"] = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            outcome["windowOrderRestored"] = Self.orderRestored(targetID: targetID, previousID: previousID)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID,
               let events = try? SyntheticFocusEvents.deactivation() { SyntheticFocusEvents.send(events, to: targetPID) }
            box.set(outcome)
        }
        while box.get() == nil { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        print(String(data: try JSONSerialization.data(withJSONObject: box.get()!, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
