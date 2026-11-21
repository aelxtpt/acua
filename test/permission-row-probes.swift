import AppKit
import Foundation

@MainActor private final class ProbeQueue {
    var operations = [@MainActor @Sendable () -> Void]()
    func add(_ operation: @escaping @MainActor @Sendable () -> Void) { operations.append(operation) }
    func runFirst() { operations.removeFirst()() }
}

/// AppKit objects only: no NSWindow, activation, screen, AX or permission call.
@main enum PermissionProbeObjectChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        var rows = [[String: Any]]()
        func check(_ name: String, _ value: Bool) { rows.append(["name": name, "passed": value]) }
        typealias Registry = PermissionRowRegistry<String, NSView, String>
        do {
            let registry = Registry(environment: .native), queue = ProbeQueue()
            let first = PermissionActionSourceProbe(requirement: "first", registry: registry)
            let second = PermissionActionSourceProbe(requirement: "second", registry: registry)
            let view = first.makeProbeView()
            check("make installs callback without immediate registration", registry.entryCount == 0)
            check("action probe passes hit testing through", view.hitTest(.zero) == nil)
            first.updateProbe(view, schedule: queue.add)
            second.updateProbe(view, schedule: queue.add)
            check("update schedules separate registrations", queue.operations.count == 2 && registry.entryCount == 0)
            queue.runFirst()
            check("first queued registration executes", registry.entryCount == 1)
            view.layout()
            check("layout uses latest callback while earlier queue used captured ID", registry.entryCount == 2)
            queue.runFirst()
            view.viewDidMoveToWindow()
            check("second queue/window callbacks preserve keyed updates", registry.entryCount == 2 && queue.operations.isEmpty)
            check("unattached action has no native target", view.window == nil && registry.actionLocation(for: "first") == nil)
        }
        do {
            let registry = Registry(environment: .native), queue = ProbeQueue()
            let first = PermissionRowTransitionSourceProbe(requirement: "first", registry: registry, snapshotProvider: { _, _, _ in "first" })
            let second = PermissionRowTransitionSourceProbe(requirement: "second", registry: registry, snapshotProvider: { _, _, _ in "second" })
            let view = first.makeProbeView()
            check("source make defers registration", registry.entryCount == 0)
            check("source probe passes hit testing through", view.hitTest(.zero) == nil)
            first.updateProbe(view, schedule: queue.add)
            second.updateProbe(view, schedule: queue.add)
            queue.runFirst();view.layout()
            check("source queued update and latest layout use different IDs", registry.entryCount == 2)
            queue.runFirst();view.viewDidMoveToWindow()
            check("source repeated callbacks keep same entries", registry.entryCount == 2 && queue.operations.isEmpty)
            check("unattached source has no capture and creates no window", view.window == nil && registry.capture(for: "first") == nil && NSApp.windows.isEmpty)
        }
        do {
            let registry = Registry(environment: .native), queue = ProbeQueue()
            weak var retained: PermissionActionProbeView?
            do {
                let probe = PermissionActionSourceProbe(requirement: "owned", registry: registry)
                let view = probe.makeProbeView();retained = view
                probe.updateProbe(view, schedule: queue.add)
            }
            check("queued update retains its native probe view", retained != nil)
            queue.runFirst()
            check("registry releases weak native view after queued callback", retained == nil && registry.entryCount == 1)
        }
        check("object checks never create a window or activate application", NSApp.windows.isEmpty && !NSApp.isActive && NSApp.activationPolicy() == .prohibited)
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["passed": passed, "cases": rows.count, "results": rows,
            "nativeViewObjectsExecuted": true, "nativeWindowsOrInputCaptureAXGrantOrPowerExecuted": false,
            "unlockedGUIAcceptance": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("native view object checks: \(rows.count), passed: \(passed)")
        exit(passed ? 0 : 1)
    }
}
