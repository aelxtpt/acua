import AppKit
import ApplicationServices
import Foundation

@MainActor enum NativeInstanceBindingChecks {
    static func run(output: URL, executable: URL, directory: URL) async throws -> Int32 {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check("native instance checks begin without NSApplication", NSApp == nil)
        let child = Process()
        child.executableURL = executable; child.arguments = ["--fixture", directory.path]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let ready = directory.appendingPathComponent("ready")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        guard child.isRunning, FileManager.default.fileExists(atPath: ready.path) else { throw CocoaError(.fileReadUnknown) }
        let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
        let target = ComputerUseApplicationTarget(bundleIdentifier: bundleID, url: appURL)
        let defaultInput = ControllerNativeUserInput.environment
        check("native monitor ignores actual service PID", defaultInput.ignoredSourcePID == getpid())
        check("native monitor mask and placement are exact", ControllerNativeUserInput.eventTypes == [10,1,3,25,22] && ControllerNativeUserInput.tapConfiguration == .init(location: .annotatedSession, types: [10,1,3,25,22], tail: true, listenOnly: true))
        let inputTarget = await defaultInput.resolveTarget(.init(sourcePID: 99, targetPID: child.processIdentifier, windowID: nil))
        check("actual default process resolver returns owned app canonical path", inputTarget == target.identifier)
        let bindings = ControllerNativeInstanceBindings()
        defer { bindings.stopMonitoring() }
        let assembly = try ControllerNativeAppSnapshotBackend.Assembly.approvedCursorNative(
            analytics: { _ in preconditionFailure("Inactive constructor must not emit analytics") },
            orderingLog: { _ in }, log: { _, _ in })
        var sender = SenderRequestContext(senderPID: getpid(), responsibleIdentity: nil, ancestorIdentities: [])
        sender.clientMetadata = .init(clientType: .nodeRepl, mcpRuntime: .legacyMCP)
        let instance = try bindings.resolve(target: target, requestedIdentifier: "owned alias", create: true, sender: sender, assembly: assembly)
        let controller = instance.controller
        check("native factory creates owner for actual owned application", controller.owner.pid == child.processIdentifier && controller.owner.applicationTarget == target)
        check("native factory binds node client diff and independent runtime", instance.configuration.isAXTreeDiffingEnabled && instance.configuration.mcpRuntime == 0 && controller.owner.isAXTreeDiffingEnabled && controller.owner.mcpRuntime == 0)
        check("native factory preserves nil chat and inactive owner", controller.owner.chatID == nil && !controller.owner.isActive && bindings.manager.activeInstances.isEmpty)
        check("native constructor creates no focus or cursor", controller.owner.focusEnforcer == nil && controller.owner.virtualCursor == nil && controller.owner.accessibilityAssertion == nil)
        let reused = try bindings.resolve(target: target, requestedIdentifier: bundleID, create: false, sender: nil, assembly: assembly)
        check("later native request reuses instance and initial configuration", reused === instance && reused.controller === controller && reused.configuration.mcpRuntime == 0)
        check("native manager uses canonical key rather than bundle alias", bindings.manager.instance(for: target.identifier) === instance && bindings.manager.instance(for: bundleID) == nil)
        let queuedPID = try await instance.serialExecutor.execute { instance.controller.owner.pid }
        check("native controller is bound to its concrete per-instance queue", queuedPID == child.processIdentifier)
        let cursor = ControllerApprovedCursor()
        check("approved cursor activity starts acting without window", cursor.activityState == 0 && cursor.visibleWindowID == nil)
        controller.owner.virtualCursor = cursor
        bindings.manager.environment.setCursorActivity(controller, 2)
        check("native manager stores interruption activity without creating window", cursor.activityState == 2 && cursor.visibleWindowID == nil)
        bindings.manager.environment.setCursorActivity(controller, 1)
        check("native manager stores finished activity on the same cursor", cursor.activityState == 1 && controller.owner.virtualCursor === cursor && cursor.visibleWindowID == nil)
        controller.owner.virtualCursor = nil
        // No activation: stop exercises the queue/cleanup route without
        // a focus assertion, ordering subscription, input tap or cursor hide.
        let stopped = try await bindings.manager.stop(target.identifier) { $0.owner.deactivate() }
        check("native queued stop returns same controller and removes its key", stopped === instance && bindings.manager.instance(for: target.identifier) == nil)
        check("native queued cleanup preserves canonical stop reason", bindings.manager.wasStoppedByUser(for: target.identifier))
        bindings.manager.clearStoppedByUser(for: target.identifier)
        check("native canonical stop clear reaches same manager", !bindings.manager.wasStoppedByUser(for: target.identifier))
        try "stop".write(to: directory.appendingPathComponent("command"), atomically: true, encoding: .utf8)
        for _ in 0..<100 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        check("owned target exits and foreground remains unchanged", !child.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        check("native constructor and queue checks leave NSApplication absent", NSApp == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "cases": cases,
            "actual_native_controller_factory_and_AX_observer_constructor_executed": true,
            "actual_default_native_input_target_resolver_executed": true,
            "native_manager_queue_configuration_and_raw_stop_bound": true,
            "actual_global_input_tap_focus_AX_write_capture_or_cursor_window": false,
            "owned_target_terminal": !child.isRunning, "foreground_unchanged": NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            "normal_service_request_routing_accepted": false, "full_goal_complete": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native canonical instance bindings: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
