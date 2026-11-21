import AppKit
import Foundation
import QuartzCore

@MainActor enum NativeCursorMotionBindingChecks {
    static func run(output: URL) throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
        let prior = RemoteHostedPIPPetLocation.position
        defer {
            if let prior { RemoteHostedPIPPetLocation.set(x: prior.x, y: prior.y, available: true) }
            else { RemoteHostedPIPPetLocation.clear() }
        }
        let environment = ControllerNativeCursorAppearance.Environment.native
        RemoteHostedPIPPetLocation.clear()
        check("native appearance reads missing shared pet location", environment.petLocation() == nil)
        RemoteHostedPIPPetLocation.set(x: -18.5, y: 230.25, available: true)
        check("native appearance reads actual publisher location without coordinate conversion", environment.petLocation() == CGPoint(x: -18.5, y: 230.25))
        let plan = ControllerCursorMovePlan(frame: .zero, destinationOrigin: CGPoint(x: 20, y: 30),
            hotspot: CGPoint(x: 2, y: 4), petLocation: environment.petLocation(), wasVisible: false,
            animated: true, targetFrame: nil, interpolatedOrigin: nil)
        check("publisher location reaches motion startup plan", plan.initialWindowOrigin == CGPoint(x: -20.5, y: 226.25) && plan.temporaryOverlay)
        RemoteHostedPIPPetLocation.set(x: 100, y: 200, available: false)
        check("unavailable publisher location is nil", environment.petLocation() == nil)
        RemoteHostedPIPPetLocation.set(x: 8, y: 9, available: true); RemoteHostedPIPPetLocation.clear()
        check("publisher disconnect clear reaches appearance consumer", environment.petLocation() == nil)
        check("fade duration and blur radius match the configured constants", ControllerNativeCursorAppearance.fadeDuration == 0.44 && ControllerNativeCursorAppearance.blurRadius == 7)
        check("blur animation uses the expected key path and key", ControllerNativeCursorAppearance.blurKeyPath == "filters.gaussianBlur.inputRadius" && ControllerNativeCursorAppearance.blurAnimationKey == "cursorBlurTransition")
        let cursor = ControllerApprovedCursor()
        check("unprepared native cursor is stationary without visible identity", !cursor.isMoving && cursor.visibleWindowID == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases,
            "physical_input_screen_capture_focus_AX_action_preferences_or_window": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native cursor motion data checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }

    static func runWindow(output: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) }
        }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let prior = RemoteHostedPIPPetLocation.position
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        let cursor = ControllerApprovedCursor(); cursor.prepare(); let panel = cursor.windowForMonitoring()
        let target = NSPanel(contentRect: .init(x: 80, y: 300, width: 240, height: 140),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false; target.ignoresMouseEvents = true; target.alphaValue = 0.001
        var additional: ControllerApprovedCursor?
        defer {
            cursor.hide(); panel.close(); additional?.hide(); additional?.windowForMonitoring().close(); target.close()
            if let prior { RemoteHostedPIPPetLocation.set(x: prior.x, y: prior.y, available: true) }
            else { RemoteHostedPIPPetLocation.clear() }
        }
        func cgHotspot(_ window: ControllerNativeCursorWindow) -> CGPoint {
            .init(x: window.frame.minX+window.tipOffset.x, y: height-window.frame.minY-window.tipOffset.y)
        }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x-b.x, a.y-b.y) <= 1 }
        func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 3) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
        RemoteHostedPIPPetLocation.clear()
        let goal = CGPoint(x: 250.25, y: 350.75)
        var immediate: [Bool] = []
        cursor.place(at: goal, active: true, animated: false, targetWindowID: nil, timing: .finished) { immediate.append($0) }
        check("native immediate placement completes synchronously and is stationary", immediate == [true] && !cursor.isMoving)
        check("native immediate placement preserves unrounded requested hotspot", near(cgHotspot(panel), goal) && panel.isVisible && !panel.hasTemporaryMovementReason)
        cursor.hide()
        var fade: [Bool] = []; let start = Date()
        cursor.place(at: goal, active: true, animated: true, targetWindowID: nil, timing: .finished) { fade.append($0) }
        let animation = panel.contentView?.layer?.animation(forKey: ControllerNativeCursorAppearance.blurAnimationKey) as? CABasicAnimation
        check("hidden animated placement with no pet starts independent fade", fade.isEmpty && !cursor.isMoving && panel.isVisible)
        check("actual layer carries the blur animation", animation?.keyPath == ControllerNativeCursorAppearance.blurKeyPath && animation?.duration == 0.44 && (animation?.fromValue as? NSNumber)?.doubleValue == 7 && (animation?.toValue as? NSNumber)?.doubleValue == 0)
        check("actual layer owns a GaussianBlur filter during fade", (panel.contentView?.layer?.filters?.count ?? 0) > 0)
        let fadeFinished = try await waitFor { !fade.isEmpty }
        let elapsed = Date().timeIntervalSince(start)
        check("actual fade completes once within bounded run loop", fadeFinished && fade == [true] && elapsed < 3)
        check("actual fade removes GaussianBlur filters", panel.contentView?.layer?.filters?.isEmpty == true)
        cursor.hide()
        var older: [Bool] = [], newer: [Bool] = []
        cursor.place(at: goal, active: true, animated: true, targetWindowID: nil, timing: .finished) { older.append($0) }
        cursor.place(at: CGPoint(x: 280, y: 360), active: true, animated: false, targetWindowID: nil, timing: .finished) { newer.append($0) }
        check("new immediate move does not cancel older fade continuation", older.isEmpty && newer == [true])
        cursor.hide()
        let olderFinished = try await waitFor { !older.isEmpty }
        check("older fade survives subsequent move and hide", olderFinished && older == [true] && newer == [true] && !panel.isVisible)
        let pet = CGPoint(x: 140, y: height-280)
        RemoteHostedPIPPetLocation.set(x: pet.x, y: pet.y, available: true)
        var moved: [Bool] = []
        cursor.place(at: goal, active: true, animated: true, targetWindowID: nil, timing: .finished) { moved.append($0) }
        check("native motion starts at actual shared pet hotspot", near(cgHotspot(panel), CGPoint(x: pet.x, y: height-pet.y)) && cursor.isMoving)
        check("native pet departure owns temporary level102", panel.hasTemporaryMovementReason && panel.level.rawValue == 102)
        let movedFinished = try await waitFor { !moved.isEmpty }
        check("native motion reaches rounded destination and completes once", movedFinished && moved == [true] && near(cgHotspot(panel), goal) && !cursor.isMoving)
        check("native visual completion releases temporary movement level", !panel.hasTemporaryMovementReason && panel.level.rawValue == 0)
        var early: [Bool] = [], earlyWasMoving = false
        cursor.place(at: CGPoint(x: 400, y: 380), active: true, animated: true, targetWindowID: nil, timing: .closeEnough) {
            early.append($0); earlyWasMoving = cursor.isMoving
        }
        let earlyFinished = try await waitFor { !early.isEmpty }
        check("close-enough reply releases before visual movement finishes", earlyFinished && early == [true] && earlyWasMoving)
        let visualFinished = try await waitFor { !cursor.isMoving }
        check("close-enough visual movement finishes without a second reply", visualFinished && early == [true])
        var cancelled: [Bool] = []
        cursor.place(at: CGPoint(x: 500, y: 400), active: true, animated: true, targetWindowID: nil, timing: .finished) { cancelled.append($0) }
        check("visible cursor starts a new movement", cursor.isMoving)
        cursor.hide()
        let hiddenFrame = panel.frame
        try await Task.sleep(for: .milliseconds(80))
        check("hide stops native movement and subsequent frames", !cursor.isMoving && !panel.isVisible && panel.frame == hiddenFrame && cancelled == [false])
        target.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(50))
        let id = UInt32(target.windowNumber), native = ControllerNativeCursorAppearance.Environment.native
        let relative = ControllerApprovedCursor(appearance: .init(petLocation: native.petLocation,
            targetFrame: native.targetFrame, hitWindow: { _ in id }, fade: native.fade))
        additional = relative; relative.prepare(); let relativePanel = relative.windowForMonitoring()
        var anchored: [Bool] = []
        let relativeGoal = CGPoint(x: 200, y: height-350)
        relative.place(at: relativeGoal, active: true, animated: true, targetWindowID: id, timing: .finished) { anchored.append($0) }
        check("owned target starts anchored animation with explicit hit-provider fixture", relative.isMoving)
        target.setFrameOrigin(CGPoint(x: 120, y: 320))
        let anchoredFinished = try await waitFor { !anchored.isEmpty }
        check("actual target frame changes translate animated destination", anchoredFinished && anchored == [true] && near(cgHotspot(relativePanel), CGPoint(x: relativeGoal.x+40, y: relativeGoal.y-20)))
        check("owned motion tests preserve foreground", foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "fade_elapsed_seconds": elapsed,
            "actual_owned_cursor_windows_layers_timers_and_target_frame_lookup": true,
            "relative_case_hit_provider_injected": true,
            "physical_mouse_keyboard_screen_capture_focus_AX_action_or_preferences": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native cursor motion owned-window checks: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
