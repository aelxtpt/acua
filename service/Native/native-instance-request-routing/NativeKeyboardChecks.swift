import AppKit
import ApplicationServices
import Foundation

@MainActor enum NativeKeyboardChecks {
    static func run(output: URL, executable: URL, directory: URL) async throws -> Int32 {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let child = Process(); child.executableURL = executable; child.arguments = ["--fixture", directory.path]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let ready = directory.appendingPathComponent("ready")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        guard child.isRunning, FileManager.default.fileExists(atPath: ready.path) else { throw CocoaError(.fileReadUnknown) }
        for _ in 0..<100 where NSRunningApplication(processIdentifier: child.processIdentifier)?.isFinishedLaunching != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in nil }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS change") },
            reenable: { _ in preconditionFailure("No WS change") }, setLocation: { _, _ in preconditionFailure("No input") })
        let resources = ControllerNativeResources(context: context, lookup: { _ in nil }, windowServer: ws)
        let targeting = ControllerNativeKeyboardTarget(resources: resources)
        let host = SettingsNativeAXElement(element: AXUIElementCreateApplication(getpid()))
        let service = AXUIElementCreateApplication(child.processIdentifier)
        let application = ControllerNativeElementContext.Node(element: host,
            snapshot: .init(supported: ["AXFocusedUIElement"], values: ["AXFocusedUIElement": .init(raw: service)], requested: ["AXFocusedUIElement"]))
        let resolved = try ControllerKeyboardTargeting(backend: targeting).target(application)
        check("ordinary keyboard host PID comes from actual AX application", try targeting.ordinaryPID(application) == getpid())
        check("owned prohibited application resolves as native service", targeting.processKind(child.processIdentifier) == .service)
        check("actual hosted keyboard PID is selected without a window ID", resolved.pid == child.processIdentifier)
        check("keyboard target retains the focused AX element", resolved.focusedElement.map { CFEqual($0.element.element, service) } == true)
        let absent = ControllerNativeElementContext.Node(element: host,
            snapshot: .init(supported: [], values: [:], requested: ["AXFocusedUIElement"]))
        let noFocus = try ControllerKeyboardTargeting(backend: targeting).target(absent)
        check("known absent focused attribute keeps host without live AX fallback", noFocus.pid == getpid() && noFocus.focusedElement == nil)
        let key = try ControllerHeldClickKey.parse("Return")
        check("key table resolves Return as physical key 36", key.keyCode == 36 && key.eventFlags == 0 && key.carbonModifiers == 0)
        let native = ControllerNativeKeyboardEvents.factory()
        let forced = ControllerKeyboardEventFactory(source: native.source, currentFlags: { 0x110000 },
            flagsEvent: native.flagsEvent, keyboardEvent: native.keyboardEvent)
        let events = try forced.make([.init(keyCode: 36, flags: 0, unicode: nil)])
        check("native constructor creates modifier/down/up/restore sequence", events.map(\.event.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        check("native sequence preserves requested and restored flag bits", events.map { $0.event.flags.rawValue } == [0, 0, 0, 0x110000])
        check("native Return events carry actual physical key code", events[1].event.getIntegerValueField(.keyboardEventKeycode) == 36 && events[2].event.getIntegerValueField(.keyboardEventKeycode) == 36)
        check("native events use HID source state1", events.allSatisfy { $0.event.getIntegerValueField(.eventSourceStateID) == 1 })
        let units: [UInt16] = [0x41, 0xD83D, 0xDE00, 0, 0x62]
        let textFactory = ControllerKeyboardEventFactory(source: native.source, currentFlags: { 0 },
            flagsEvent: native.flagsEvent, keyboardEvent: native.keyboardEvent)
        let text = try textFactory.make([.init(keyCode: 0, flags: 0, unicode: units)])
        func unicode(_ event: CGEvent) -> [UInt16] {
            var buffer = [UInt16](repeating: 0, count: 64); var count = 0
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
            return Array(buffer.prefix(count))
        }
        check("real native Unicode payload retains surrogate and null code units", text.count == 2 && text.allSatisfy { unicode($0.event) == units })
        let automatic = try await ControllerNativeKeyboardEvents.make([.init(keyCode: 36, flags: 0, unicode: nil)])
        let automaticKeys = automatic.filter { $0.event.type == .keyDown || $0.event.type == .keyUp }
        check("default async native factory creates Return without posting", [2, 4].contains(automatic.count) && automaticKeys.map(\.event.type) == [.keyDown, .keyUp] && automaticKeys.allSatisfy { $0.event.getIntegerValueField(.keyboardEventKeycode) == 36 && $0.event.flags.rawValue == 0 })
        var posted: [(Int32, UInt64)] = []; var tick: UInt64 = 1000
        ControllerKeyboardImmediateSender<ControllerFocusNativeEvent>(timestamp: { defer { tick += 1 }; return tick },
            setTimestamp: { $0.event.timestamp = $1 }, post: { posted.append(($1, $0.event.timestamp)) }).send(text, to: 909)
        check("native CGEvent timestamps are changed before injected posting", posted.map(\.0) == [909, 909] && posted.map(\.1) == [1000, 1001])
        let runtime = ControllerNativeSetValueRuntime.native(resources: resources)
        withExtendedLifetime(runtime) {}
        check("default native setValue runtime constructs without starting AppKit", NSApp == nil)
        try "stop".write(to: directory.appendingPathComponent("command"), atomically: true, encoding: .utf8)
        for _ in 0..<100 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        check("owned target exits without foreground change", !child.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": checks,
            "actual_native_CGEvent_constructors_and_Unicode_payload_executed": true,
            "actual_native_hosted_keyboard_target_and_process_policy_executed": true,
            "current_flags_injected_for_deterministic_constructor_vectors": true,
            "default_async_native_factory_executed_without_posting": true,
            "native_CGEvent_timestamps_mutated_with_injected_post": true,
            "actual_keyboard_delivery_focus_capture_or_AX_write": false,
            "owned_target_terminal": !child.isRunning, "foreground_unchanged": NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            "native_setValue_Return_runtime_constructed": true, "normal_native_request_routing_accepted": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native keyboard: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
