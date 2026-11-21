import AppKit
import ApplicationServices
import Foundation

private final class ElementClickCursorLease: ControllerCursorMonitorLease, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var stops: Int { lock.withLock { value } }
    func stop() { lock.withLock { value += 1 } }
}

@MainActor enum NativeElementClickCorrectionChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        for bundle: String? in [nil, "com.apple.Safari", "org.chromium.Chromium", "com.example.agent"] {
            let f = NativeLowerFixture(bundleIdentifier: bundle), resolved = try f.resolved()
            let lower = ControllerNativeLowerClick(resolved: resolved, captured: f.captured, resources: f.resources, cursor: nil)
            check("native element without AXWebArea ancestor is not web-shaped for \(bundle ?? "nil")", !lower.webShaped() && f.rows.actions.isEmpty)
        }
        for depth in [0, 1, 300, 301] {
            let f = NativeLowerFixture()
            var parent = f.leaf
            if depth == 0 {
                f.rows.set(f.leaf, ["AXRole": .init(raw: "AXWebArea" as NSString)])
            } else {
                for index in 1...depth {
                    let next = SettingsNativeAXElement(element: AXUIElementCreateApplication(Int32(80000 + index)))
                    f.rows.set(parent, ["AXRole": .init(raw: "AXGroup" as NSString), "AXParent": .init(raw: next.element)])
                    parent = next
                }
                f.rows.set(parent, ["AXRole": .init(raw: "AXWebArea" as NSString)])
            }
            let lower = ControllerNativeLowerClick(resolved: try f.resolved(), captured: f.captured, resources: f.resources, cursor: nil)
            check("native inclusive AXWebArea depth \(depth) respects the depth bound", lower.webShaped() == (depth <= 300))
        }
        do {
            let f = NativeLowerFixture()
            f.rows.set(f.leaf, ["AXRole": .init(raw: "AXGroup" as NSString), "AXParent": .init(raw: f.leaf.element)])
            let lower = ControllerNativeLowerClick(resolved: try f.resolved(), captured: f.captured, resources: f.resources, cursor: nil)
            check("native cyclic parent chain terminates without AX action", !lower.webShaped() && f.rows.actions.isEmpty)
        }
        for (webArea, hit, expectedMouse): (Bool, Bool, Bool) in [(true, true, true), (true, false, false), (false, true, false), (false, false, false)] {
            let f = NativeLowerFixture()
            if webArea {
                var leafRow = f.rows.values(f.leaf)
                leafRow["AXRole"] = .init(raw: "AXWebArea" as NSString)
                f.rows.set(f.leaf, leafRow)
            }
            if hit { f.rows.set(f.app, ["AXRole": .init(raw: "AXApplication" as NSString), "AXFixtureHit": .init(raw: f.leaf.element)]) }
            let resolved = try f.resolved()
            let runtime = ControllerNativeClickRuntime.nativeClick(resources: f.resources, settle: { _, _, _, _ in nil })
            var mouse = false
            do {
                // AXPick permits count zero; the eligible web-hit mouse path
                // rejects it BEFORE constructing or posting any mouse event.
                try await runtime.click(resolved, f.captured,
                    .init(button: .left, count: 0, hold: nil, key: .none, alwaysSimulate: false), nil)
            } catch ControllerLowerClickFailure.invalidCount { mouse = true }
            check("native dispatch webArea=\(webArea) hit=\(hit) chooses AX or mouse path", mouse == expectedMouse && f.rows.actions == (expectedMouse ? [] : ["AXPick"]))
            check("native dispatch keeps the no-refetch action contract webArea=\(webArea) hit=\(hit)", f.probes == 0)
        }
        for installsMonitor in [true, false] {
            let f = SecondaryScrollDataNativeFixture()
            let owner = try NativeSecondaryScrollDataAppSnapshotBindingChecks.owner(f)
            let controller = ControllerNativeAppController(owner: owner, resources: f.resources)
            let ax = ElementClickCursorLease(), active = ElementClickCursorLease()
            var trace: [String] = [], reasons: [Bool] = [], names: [String] = []
            var publishedBeforeWindow = false, pidBeforeWindow = false, monitorPID: Int32?
            let handle = ControllerCursorMonitorWindow(isVisible: { false },
                setApplicationReason: { reasons.append($0) }, retarget: { _ in preconditionFailure("No retarget") })
            let monitorEnvironment = ControllerNativeCursorAppMonitor.Environment(
                runningApplication: { _ in .init(application: .current) }, isActive: { _ in false },
                primaryWindow: { _ in nil }, windowID: { _ in preconditionFailure("No window query") },
                isVisible: { $0.isVisible() }, setApplicationOverlayReason: { $0.setApplicationReason($1) },
                retargetVisibleWindow: { $0.retarget($1) }, observeAX: { _, pid, ordered, _ in
                    trace.append("AX"); monitorPID = pid; names = ordered; return ax
                }, observeActive: { _, _ in trace.append("KVO"); return active },
                enqueue: { _ in preconditionFailure("No observation queued") })
            let creation = ControllerNativeCursorCreationEnvironment(makeCursor: {
                trace.append("create"); return ControllerApprovedCursor()
            }, window: { cursor in
                trace.append("window"); publishedBeforeWindow = owner.virtualCursor === cursor
                pidBeforeWindow = cursor.correspondingApplicationPID == owner.pid; return handle
            }, application: { pid in
                trace.append("app"); precondition(pid == owner.pid); return owner.app
            }, monitor: { app, pid, window in
                trace.append("monitor")
                return installsMonitor ? .init(application: app, pid: pid, window: window, environment: monitorEnvironment) : nil
            })
            let runtime = ControllerNativeClickRuntime.native(resources: f.resources, settleEnvironment: f.environment)
            let backend = ControllerNativeClickBackend(controller: controller, runtime: runtime, cursorCreationEnvironment: creation)
            let cursor = backend.ensureCursor()
            let expected = installsMonitor ? ["create", "window", "app", "monitor", "AX", "KVO"] : ["create", "window", "app", "monitor"]
            check("fresh element-click cursor uses complete factory monitor=\(installsMonitor)", trace == expected && publishedBeforeWindow && pidBeforeWindow && owner.virtualCursor === cursor)
            check("fresh click cursor stores associated owner PID monitor=\(installsMonitor)", cursor.correspondingApplicationPID == owner.pid)
            check("fresh click factory installs exact optional monitor=\(installsMonitor)", (handle.appMonitor != nil) == installsMonitor && (!installsMonitor || monitorPID == owner.pid && names == ["AXFocusedWindowChanged", "AXMenuOpened", "AXMenuClosed"] && reasons == [false]))
            let ordinary = ControllerNativeClickBackend(controller: controller, runtime: runtime)
            check("existing click cursor bypasses all construction and monitor replacement=\(installsMonitor)", backend.ensureCursor() === cursor && ordinary.ensureCursor() === cursor && trace == expected)
            check("fresh click binding preserves approved cursor without native panel or focus=\(installsMonitor)", cursor.visibleWindowID == nil && !owner.isActive && owner.focusEnforcer == nil && owner.accessibilityAssertion == nil)
            handle.appMonitor = nil; owner.virtualCursor = nil
            check("optional click monitor releases both observer leases=\(installsMonitor)", ax.stops == (installsMonitor ? 1 : 0) && active.stops == (installsMonitor ? 1 : 0))
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks,
            "native_lower_click_and_fresh_cursor_factory_bindings_executed": true,
            "AX_hit_and_observer_effect_providers_injected": true,
            "actual_input_focus_cursor_window_capture_preferences_or_clipboard": false,
            "ordinary_native_request_routing_accepted": false,
            "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native element click corrections: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
