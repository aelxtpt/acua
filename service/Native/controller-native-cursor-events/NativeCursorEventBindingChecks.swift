import AppKit
import Foundation

@MainActor private final class CursorEventFixtureLink: SystemSettingsDisplayLinkObject {
    var timestamp = 0.0, duration = 1.0/240, targetTimestamp = 1.0/240
    var starts = 0, stops = 0
    func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) { starts += 1 }
    func invalidate() { stops += 1 }
}

@MainActor enum NativeCursorEventBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let cursor = ControllerApprovedCursor()
        check("native pressed getter reads unprepared state without window allocation", !cursor.isPressed && !cursor.isMoving && cursor.visibleWindowID == nil)
        try await cursor.press(count: 2)
        check("native hidden repeat press returns without allocating window", !cursor.isPressed && cursor.visibleWindowID == nil)
        try await cursor.press(count: -1)
        check("native hidden negative press preserves visibility-before-validation order", !cursor.isPressed && cursor.visibleWindowID == nil)
        let driverLink = CursorEventFixtureLink(), bounds = CGRect(x: -1000, y: -1000, width: 3000, height: 3000)
        let driver = SystemSettingsDisplayLinkDriver { _, _ in driverLink }
        var run = ControllerCursorAnimationEvents(start: .zero, end: CGPoint(x: 100, y: 20), bounds: bounds)
        var names: [String] = []
        driver.frameCallback = { tick in
            for event in run.advance(timestamp: tick.timestamp, targetTimestamp: tick.targetTimestamp) {
                if case .valueChanged = event { names.append("value") } else { names.append("finished") }
            }
        }
        driver.start(); driver.displayLinkDidFire()
        check("native driver suppresses unchanged first animation value", names.isEmpty && driverLink.starts == 1)
        driverLink.timestamp = 1.0/240; driverLink.targetTimestamp = 2.0/240; driver.displayLinkDidFire()
        check("native driver delivers next changed animation value", names == ["value"])
        driver.displayLinkDidFire()
        check("native driver repeated prediction does not duplicate value event", names == ["value"])
        driver.stop()
        check("native event fixture releases its driver once", driverLink.stops == 1 && !driver.isActive)
        var stationary = ControllerCursorAnimationEvents(start: .zero, end: .zero, bounds: bounds)
        let stationaryEvents = stationary.advance(timestamp: 0, targetTimestamp: 0)
        check("native stationary event stream finishes without fabricated valueChanged", stationaryEvents.count == 1 && stationary.isFinished)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "all_owned_tasks_terminal": true,
            "native_display_link_creation_provider_injected": true, "actual_native_cursor_press_and_event_adapters_executed": true,
            "physical_input_window_capture_focus_AX_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native cursor event data checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
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
            cursor.setPressed(false); cursor.hide(); panel.close()
            if let prior { RemoteHostedPIPPetLocation.set(x: prior.x, y: prior.y, available: true) }
            else { RemoteHostedPIPPetLocation.clear() }
        }
        func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 2) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            return condition()
        }
        let initial = CGPoint(x: 250, y: 350)
        cursor.place(at: initial, active: true, animated: false, targetWindowID: nil, timing: .finished)
        var stationary: [Bool] = [], movingAtReadiness = false
        cursor.place(at: initial, active: true, animated: true, targetWindowID: nil, timing: .closeEnough) {
            stationary.append($0); movingAtReadiness = cursor.isMoving
        }
        let stationaryFinished = try await waitFor { !stationary.isEmpty && !cursor.isMoving }
        check("stationary native completion releases readiness before visual cleanup", stationaryFinished && stationary == [true] && movingAtReadiness)
        var old: [Bool] = [], next: [Bool] = []
        cursor.place(at: initial, active: true, animated: true, targetWindowID: nil, timing: .closeEnough) { value in
            old.append(value)
            cursor.place(at: CGPoint(x: 330, y: 370), active: true, animated: true, targetWindowID: nil, timing: .finished) { next.append($0) }
        }
        let nextFinished = try await waitFor { !next.isEmpty }
        check("readiness callback can start another native movement without stale cleanup", nextFinished && old == [true] && next == [true] && !cursor.isMoving)
        let frame = panel.frame
        cursor.setPressed(true)
        let artwork = panel.contentView?.layer?.sublayers?.first?.sublayers?.first
        let scale = (artwork?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue
        check("native press state reaches actual approved artwork without moving hotspot", cursor.isPressed && scale == 0.94 && panel.frame == frame)
        cursor.place(at: CGPoint(x: 550, y: 370), active: true, animated: true, targetWindowID: nil, timing: .finished)
        check("starting native movement preserves held cursor pressure", cursor.isMoving && cursor.isPressed)
        cursor.hide()
        check("native hide preserves style pressure until its owner releases it", cursor.isPressed && !cursor.isMoving && !panel.isVisible)
        cursor.setPressed(false)
        check("native release updates retained artwork while hidden", !cursor.isPressed && (artwork?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue == 1)
        cursor.place(at: initial, active: true, animated: false, targetWindowID: nil, timing: .finished)
        var done = false, observed: [Bool] = [false]
        let start = Date()
        let presses = Task { @MainActor in defer { done = true }; try await cursor.press(count: 2) }
        let pressDeadline = Date().addingTimeInterval(2)
        while !done, Date() < pressDeadline {
            let value = cursor.isPressed
            if observed.last != value { observed.append(value) }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await presses.value
        if observed.last != cursor.isPressed { observed.append(cursor.isPressed) }
        let elapsed = Date().timeIntervalSince(start)
        check("native repeat press exposes two down-up cycles", observed == [false, true, false, true, false])
        check("native repeat press awaits actual timing and ends released", done && !cursor.isPressed && elapsed >= 0.23 && elapsed < 2)
        let hiddenPress = Task { @MainActor in try await cursor.press() }
        let pressed = try await waitFor { cursor.isPressed }
        cursor.hide(); try await hiddenPress.value
        check("in-flight native press completes release after its window is hidden", pressed && !cursor.isPressed && !panel.isVisible && cursor.visibleWindowID == nil)
        check("owned event and press tests preserve foreground", foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "repeat_press_elapsed_seconds": elapsed,
            "observed_press_states": observed, "actual_owned_native_readiness_pressure_and_repeat_press_executed": true,
            "physical_mouse_keyboard_screen_capture_focus_AX_action_or_preferences": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native cursor event owned-window checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
