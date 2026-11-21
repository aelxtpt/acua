import AppKit
import ApplicationServices
import Carbon
import Foundation

private final class TypingTrace: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}
private enum TypingFailure: Error { case event }

@MainActor enum NativeKeyboardActionChecks {
    ///A native layout sample supplies a supported BMP test input independent
    ///of the user's chosen layout, instead of assuming an English keyboard.
    static func sample() -> (text: String, code: UInt16, units: [UInt16])? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return withExtendedLifetime(source) {
            bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                for code in UInt16(0)...127 {
                    var dead: UInt32 = 0, length = 0
                    var units = [UInt16](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, 3, 0, UInt32(LMGetKbdType()), 0, &dead, units.count, &length, &units)
                    if status == 0 && length > 0 && units[0] > 31 && !(0xd800...0xdfff).contains(units[0]) {
                        return (String(decoding: [units[0]], as: UTF16.self), code, Array(units.prefix(length)))
                    }
                }
                return nil
            }
        }
    }
    static func run(output: URL) async throws -> Int32 {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); if !passed { print("FAIL: " + name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let context = ControllerNativeElementContext(currentTransaction: { nil }, lookup: { _ in nil }, log: { _, _ in })
        let ws = ControllerNativeWindowServer(mainConnection: { nil }, disable: { _ in preconditionFailure("No WS change") },
            reenable: { _ in preconditionFailure("No WS change") }, setLocation: { _, _ in preconditionFailure("No input") })
        let resources = ControllerNativeResources(context: context, lookup: { _ in nil }, windowServer: ws)
        let runtime = ControllerNativeKeyboardActionRuntime.native(resources: resources)
        let baseline = sample()
        check("current native TIS layout exposes a supported test character", baseline != nil)
        var nativeUnits: [UInt16] = []
        if let baseline {
            let strokes = ControllerNativeKeyboardTextTranslation.translate(baseline.text)
            nativeUnits = strokes?.flatMap { $0.unicode ?? [] } ?? []
            check("native layout translation matches live UC fixture", strokes == [.init(keyCode: baseline.code, flags: 0, unicode: baseline.units)])
            let events = try await runtime.type(baseline.text)
            let keys = events.filter { $0.event.type == .keyDown || $0.event.type == .keyUp }
            func unicode(_ event: CGEvent) -> [UInt16] {
                var buffer = [UInt16](repeating: 0, count: 64); var length = 0
                event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
                return Array(buffer.prefix(length))
            }
            check("default native typing constructs down/up for translated physical key", keys.map(\.event.type) == [.keyDown, .keyUp] && keys.allSatisfy { $0.event.getIntegerValueField(.keyboardEventKeycode) == baseline.code })
            check("default native typing embeds complete UC Unicode payload", keys.count == 2 && keys.allSatisfy { unicode($0.event) == baseline.units })
        }
        let empty = try await runtime.type("")
        check("empty native typing still translates but emits no events", empty.isEmpty)
        let press = try await runtime.press("a Return")
        let pressKeys = press.filter { $0.event.type == .keyDown || $0.event.type == .keyUp }
        check("native multi-stroke press preserves interleaved key order", pressKeys.map(\.event.type) == [.keyDown, .keyUp, .keyDown, .keyUp] && pressKeys.map { $0.event.getIntegerValueField(.keyboardEventKeycode) } == [0, 0, 36, 36])
        let held = try await runtime.holding("a Return")
        let down = held.down.filter { $0.event.type == .keyDown }
        let up = held.up.filter { $0.event.type == .keyUp }
        check("native holding aggregates down/up sequences in stroke order", down.map { $0.event.getIntegerValueField(.keyboardEventKeycode) } == [0, 36] && up.map { $0.event.getIntegerValueField(.keyboardEventKeycode) } == [0, 36])
        let holdingEmpty = try await runtime.holding("")
        check("empty native holding creates an empty pair", holdingEmpty.down.isEmpty && holdingEmpty.up.isEmpty)
        do {
            let trace = TypingTrace()
            let environment = ControllerNativeKeyboardTyping.Environment(source: { trace.add("source"); return nil },
                translate: { _ in trace.add("translate"); return [] }, events: { _, _ in trace.add("events"); return [] })
            var rejected = false
            do { _ = try await ControllerNativeKeyboardTyping.make("", environment: environment) }
            catch ControllerSynthesizedEventError.failedToCreateSource { rejected = true }
            check("source failure precedes layout lookup even for empty text", rejected && trace.snapshot == ["source"])
        }
        do {
            let trace = TypingTrace()
            let environment = ControllerNativeKeyboardTyping.Environment(source: {
                trace.add("source"); return CGEventSource(stateID: .hidSystemState).map { .init(value: $0) }
            }, translate: { _ in trace.add("translate"); return nil }, events: { _, _ in trace.add("events"); return [] })
            var rejected = false
            do { _ = try await ControllerNativeKeyboardTyping.make("", environment: environment) }
            catch ControllerSynthesizedEventError.failedToTranslateKeyCodes { rejected = true }
            check("missing layout translation propagates before event creation", rejected && trace.snapshot == ["source", "translate"])
        }
        do {
            let trace = TypingTrace()
            let environment = ControllerNativeKeyboardTyping.Environment(source: {
                trace.add("source"); return CGEventSource(stateID: .hidSystemState).map { .init(value: $0) }
            }, translate: { _ in trace.add("translate"); return [] }, events: { _, _ in trace.add("events"); return [] })
            let events = try await ControllerNativeKeyboardTyping.make("", environment: environment)
            check("empty text preserves source-translation-event ordering", events.isEmpty && trace.snapshot == ["source", "translate", "events"])
        }
        do {
            let trace = TypingTrace()
            let environment = ControllerNativeKeyboardTyping.Environment(source: {
                trace.add("source"); return CGEventSource(stateID: .hidSystemState).map { .init(value: $0) }
            }, translate: { _ in trace.add("translate"); return [] }, events: { _, _ in trace.add("events"); throw TypingFailure.event })
            var rejected = false
            do { _ = try await ControllerNativeKeyboardTyping.make("a", environment: environment) }
            catch TypingFailure.event { rejected = true }
            check("event-creation failure propagates after translation", rejected && trace.snapshot == ["source", "translate", "events"])
        }
        check("native layout and constructors preserve foreground", NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": checks,
            "actual_TIS_layout_UCKeyTranslate_and_CGEvent_constructors_executed": true,
            "default_native_type_press_hold_event_providers_executed": true,
            "source_translation_event_failure_boundaries_verified_with_injected_dependencies": true,
            "native_sample_UTF16": nativeUnits, "client_NSApplication_initialized": NSApp != nil,
            "actual_keyboard_post_focus_capture_or_AX_write": false,
            "whole_native_controller_keyboard_operation_executed": false,
            "normal_native_request_routing_accepted": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native keyboard actions: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
