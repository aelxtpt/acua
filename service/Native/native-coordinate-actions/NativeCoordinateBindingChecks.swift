import AppKit
import ApplicationServices
import Foundation

@MainActor enum NativeCoordinateBindingChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let f = SecondaryScrollDataNativeFixture()
        let owner = try NativeSecondaryScrollDataAppSnapshotBindingChecks.owner(f)
        let controller = ControllerNativeAppController(owner: owner, resources: f.resources)
        let backend = ControllerNativeCoordinateClickBackend(controller: controller)
        let exact = ControllerScaledCursorPosition(x: 9_007_199_254_740_993, y: Int64.min)
        backend.position = exact
        check("native controller owner retains raw Int64 coordinate identity", owner.scaledCursorPosition == exact && backend.position == exact)
        owner.cursorPositionInScaledCoordinates = .init(x: 7.75, y: -11.75)
        check("CGPoint compatibility setter truncates toward zero into raw storage", owner.scaledCursorPosition == .init(x: 7, y: -11) && owner.cursorPositionInScaledCoordinates == .init(x: 7, y: -11))
        owner.scalingFactor = 2; owner.visibleRect = .init(x: -30, y: 40, width: 100, height: 200)
        check("coordinate native mapping reads shared owner scale and visible origin", backend.global(backend.position) == .init(x: -16, y: 18))
        let scroll = ControllerNativeScrollBackend(controller: controller, runtime: .native(resources: f.resources))
        check("existing scroll maps the same canonical Int64 owner position", scroll.point() == backend.global(backend.position))
        let window = f.resources.context.context.node(f.window), child = f.resources.context.context.node(f.child)
        let delivery = ControllerMouseEventTarget(pid: 74022, element: child, accessibilityWindow: window,
            windowID: 999, windowBounds: .init(x: 10, y: 20, width: 300, height: 200))
        let menu = ControllerNativeCoordinateSelection(entry: .init(node: window, kind: .menu), delivery: delivery)
        check("native menu kind survives a refined receiver and non-menu AX role", backend.isMenu(menu) && f.resources.context.context.role(window) == "AXWindow" && menu.delivery.pid == 74022)
        check("native cursor uses selected menu protocol window ID independently of delivery ID", try backend.cursorWindowID(menu) == 51 && menu.delivery.windowID == 999)
        let ordinary = ControllerNativeCoordinateSelection(entry: .init(node: window, kind: .sheet), delivery: delivery)
        let ordinaryWindowID = try backend.cursorWindowID(ordinary)
        check("native sheet preserves ordinary movement branch and source window ID", !backend.isMenu(ordinary) && ordinaryWindowID == 51)
        try backend.pressMenu(menu)
        check("native menu press uses shared hosted AX action executor", f.rows.actions == ["AXPress"])
        f.rows.setNames(["AXCancel"]); var missing = false
        do { try backend.pressMenu(menu) } catch ControllerCoordinateClickFailure.cannotPressMenuItem { missing = true }
        check("native missing press action fails before performing another hosted action", missing && f.rows.actions == ["AXPress"])
        let absent = ControllerNativeCoordinateSelection(entry: menu.entry,
            delivery: .init(pid: 74022, element: nil, accessibilityWindow: window, windowID: 999, windowBounds: .zero))
        missing = false
        do { try backend.pressMenu(absent) } catch ControllerCoordinateClickFailure.cannotPressMenuItem { missing = true }
        check("native menu without hit element fails without guessing selected menu as leaf", missing && f.rows.actions == ["AXPress"])
        backend.needsUISettleBeforeAppSnapshot = true
        check("native coordinate deferred settle flag shares canonical owner", owner.needsUISettleBeforeAppSnapshot)
        var invalid = false
        let before = backend.position
        do { _ = try await controller.coordinateClick(.init(position: .zero, key: "invalid-held-key")) } catch ControllerHeldClickKeyFailure.unknownSymbol { invalid = true }
        check("native public coordinate entry parses key before changing owner or creating cursor", invalid && backend.position == before && owner.virtualCursor == nil)
        check("native binding construction and owned AX actions do not activate owner or focus", !owner.isActive && owner.virtualCursor == nil && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks,
            "native_controller_owner_and_hosted_action_bindings_executed": true,
            "actual_mouse_keyboard_focus_cursor_window_capture_preferences_or_clipboard": false,
            "ordinary_request_routing_accepted": false,
            "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native coordinate bindings: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
