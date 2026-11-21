import AppKit
import Foundation

@MainActor private final class CursorSpringFixtureLink: SystemSettingsDisplayLinkObject {
    var timestamp = 100.0, duration = 1.0/60, targetTimestamp = 100.0+1.0/60
    var additions = 0, invalidations = 0
    func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) { precondition(mode == .common); additions += 1 }
    func invalidate() { invalidations += 1 }
}

@MainActor enum NativeCursorSpringBindingChecks {
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let link = CursorSpringFixtureLink()
        let driver = SystemSettingsDisplayLinkDriver { _, _ in link }
        var engine = ControllerCursorMotionEngine(start: .zero, end: CGPoint(x: 100, y: 20), bounds: CGRect(x: -1000, y: -1000, width: 2000, height: 2000))
        var ticks: [SystemSettingsAnimationFrame] = [], frames: [ControllerCursorMotionEngine.Frame] = []
        driver.frameCallback = { tick in ticks.append(tick); frames.append(engine.advance(frameTimestamp: tick.timestamp, targetTimestamp: tick.targetTimestamp)) }
        driver.start(); driver.start()
        check("native display driver registers common-mode link once", link.additions == 1 && driver.isActive)
        driver.displayLinkDidFire()
        check("native display driver forwards actual timestamp duration and target", ticks == [.init(timestamp: 100, duration: 1.0/60, targetTimestamp: 100.0+1.0/60)])
        check("native predicted-frame tick advances position spring without clock-gap jump", frames.count == 1 && frames[0].point.x > 0 && frames[0].point.x < 20 && !frames[0].finished)
        link.timestamp += 1.0/60; link.targetTimestamp += 1.0/60
        driver.displayLinkDidFire()
        check("next native tick retains simulation time and increases displacement", frames.count == 2 && frames[1].point.x > frames[0].point.x)
        driver.stop(); driver.stop()
        check("native driver stop invalidates once", !driver.isActive && link.invalidations == 1)
        let releasedLink = CursorSpringFixtureLink()
        var released: SystemSettingsDisplayLinkDriver? = .init { _, _ in releasedLink }
        released?.start(); released = nil
        check("active native driver deinit invalidates its owned link", releasedLink.additions == 1 && releasedLink.invalidations == 1)
        var long = ControllerCursorMotionEngine(start: .zero, end: CGPoint(x: 800, y: 100), bounds: CGRect(x: -1000, y: -1000, width: 3000, height: 3000))
        let frame = long.advance(frameTimestamp: 1000, targetTimestamp: 1000+1.0/60)
        check("native long-motion engine selects the progress path", long.mode == .progress && long.path != nil && !frame.finished && frame.progress > 0)
        check("native long-motion output includes curve tangent velocity", hypot(frame.velocity.x, frame.velocity.y) > 0 && frame.point != .zero)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "native_display_link_creation_provider_injected": true, "actual_native_driver_and_engine_methods_executed": true,
            "physical_input_window_capture_focus_AX_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native cursor spring data checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }

    static func runWindow(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let prior = RemoteHostedPIPPetLocation.position
        RemoteHostedPIPPetLocation.clear()
        let cursor = ControllerApprovedCursor(); cursor.prepare(); let panel = cursor.windowForMonitoring()
        defer {
            cursor.hide(); panel.close()
            if let prior { RemoteHostedPIPPetLocation.set(x: prior.x, y: prior.y, available: true) }
            else { RemoteHostedPIPPetLocation.clear() }
        }
        let height = NSScreen.screens.first?.frame.maxY ?? 0, width = NSScreen.screens.first?.frame.width ?? 1000
        let initial = CGPoint(x: 100, y: min(height*0.4, 250)), goal = CGPoint(x: min(width-100, 700), y: min(height*0.4, 250))
        func point() -> CGPoint { CGPoint(x: panel.frame.minX+panel.tipOffset.x, y: height-panel.frame.minY-panel.tipOffset.y) }
        cursor.place(at: initial, active: true, animated: false, targetWindowID: nil, timing: .finished)
        var results: [Bool] = [], samples: [CGPoint] = []
        cursor.place(at: goal, active: true, animated: true, targetWindowID: nil, timing: .finished) { results.append($0) }
        check("owned native long movement starts without physical input", cursor.isMoving && panel.isVisible && results.isEmpty)
        let deadline = Date().addingTimeInterval(4)
        while results.isEmpty, Date() < deadline {
            samples.append(point()); try await Task.sleep(for: .milliseconds(10))
        }
        check("actual window display link drives multiple changing frames", Set(samples.map { "\($0.x),\($0.y)" }).count > 5)
        check("actual native long movement follows curved trajectory", samples.contains { abs($0.y-initial.y) > 2 })
        check("actual long movement finishes once at rounded destination", results == [true] && !cursor.isMoving && hypot(point().x-goal.x, point().y-goal.y) <= 1)
        var cancelled: [Bool] = []
        cursor.place(at: initial, active: true, animated: true, targetWindowID: nil, timing: .finished) { cancelled.append($0) }
        cursor.hide(); let hidden = panel.frame
        try await Task.sleep(for: .milliseconds(80))
        check("hide invalidates native link and cancels long movement once", cancelled == [false] && !cursor.isMoving && !panel.isVisible && panel.frame == hidden)
        cursor.place(at: initial, active: true, animated: false, targetWindowID: nil, timing: .finished)
        var restarted: [Bool] = []
        cursor.place(at: goal, active: true, animated: true, targetWindowID: nil, timing: .finished) { restarted.append($0) }
        let restartDeadline = Date().addingTimeInterval(4)
        while restarted.isEmpty, Date() < restartDeadline { try await Task.sleep(for: .milliseconds(10)) }
        check("new movement obtains a fresh native link after cancellation", restarted == [true] && !cursor.isMoving && hypot(point().x-goal.x, point().y-goal.y) <= 1)
        check("native display-link movement preserves foreground", foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "sample_count": samples.count,
            "actual_owned_window_display_link_and_long_curve_executed": true,
            "physical_mouse_keyboard_screen_capture_focus_AX_action_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native cursor spring owned-window checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
