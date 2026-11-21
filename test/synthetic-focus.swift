import AppKit

@main enum SyntheticFocusTests {
    static func main() throws {
        _ = NSApplication.shared
        var passed = 0
        func check(_ name: String, _ valid: Bool) { precondition(valid, name); passed += 1; print("PASS \(name)") }
        for (type, subtype, expected) in [(UInt32(13), Int64(1), true), (13, 2, false), (19, 0, false), (20, 0, true)] {
            var state = SyntheticFocusState(believesActive: !expected, believesFocused: !expected, actuallyActive: false)
            state.observe(type: type, subtype: subtype)
            check("event \(type)/\(subtype) updates receiver activation and focus", state.believesActive == expected && state.believesFocused == expected)
            check("receiver event cannot change actual activation", !state.actuallyActive)
        }
        let initial = SyntheticFocusState(believesActive: true, believesFocused: false, actuallyActive: true)
        for (type, subtype) in [(UInt32(13), Int64(0)), (13, 65537), (21, -32768), (22, 1)] {
            var state = initial; state.observe(type: type, subtype: subtype)
            check("unrelated event \(type)/\(subtype) preserves state", state == initial)
        }
        check("active receiver lacking key focus needs return notification", initial.needsKeyFocusReturn && !initial.needsActivation)
        check("real active app is not synthetically deactivated", !initial.needsDeactivation)
        let synthetic = SyntheticFocusState(believesActive: true, believesFocused: true, actuallyActive: false)
        check("invented activation needs explicit teardown", synthetic.needsDeactivation)
        let inactive = SyntheticFocusState(believesActive: false, believesFocused: false, actuallyActive: false)
        check("inactive receiver needs activation", inactive.needsActivation && !inactive.needsKeyFocusReturn)

        let empty = try SyntheticFocusEvents.activation()
        let bare = NSEvent(cgEvent: empty[0])!
        check("missing activation point generates only the activation packet", empty.count == 1)
        check("activation packet uses type13/subtype1", bare.type.rawValue == 13 && bare.subtype.rawValue == 1)
        check("activation without window has no window flags", bare.windowNumber == 0 && bare.modifierFlags.rawValue == 0)
        let frame = CGRect(x: -500, y: 90, width: 300, height: 400), point = CGPoint(x: -470, y: 106)
        let events = try SyntheticFocusEvents.activation(windowID: 777, frame: frame, activationPoint: point)
        let activate = NSEvent(cgEvent: events[0])!
        check("window activation has the expected flag mask and association", activate.windowNumber == 777 && activate.modifierFlags.rawValue == 786432)
        check("window activation precedes both activation mouse packets", events.count == 3 && events[1].type == .leftMouseDown && events[2].type == .leftMouseUp)
        for (index, event) in events.dropFirst().enumerated() {
            check("activation mouse \(index) uses global geometry", event.location == point)
            check("activation mouse \(index) carries click state3, number0 and window91/92",
                event.getIntegerValueField(.mouseEventClickState) == 3 && event.getIntegerValueField(.mouseEventNumber) == 0 &&
                event.getIntegerValueField(CGEventField(rawValue: 91)!) == 777 && event.getIntegerValueField(CGEventField(rawValue: 92)!) == 777)
            check("activation mouse \(index) does not hold modifiers", event.flags.rawValue == 0)
        }
        let key = NSEvent(cgEvent: try SyntheticFocusEvents.keyFocusReturned()[0])!
        check("focus return uses private process-notification type21 and subtype0x8000", key.type.rawValue == 21 && key.subtype.rawValue == Int16(bitPattern: 0x8000))
        let deactivation = NSEvent(cgEvent: try SyntheticFocusEvents.deactivation()[0])!
        check("deactivation uses type13/subtype2 without a window", deactivation.type.rawValue == 13 && deactivation.subtype.rawValue == 2 && deactivation.windowNumber == 0)
        let invalid = try SyntheticFocusEvents.activation(windowID: 777, frame: .zero, activationPoint: point)
        check("invalid geometry never emits activation clicks", invalid.count == 1)
        var policy = FocusRestorationPolicy(now: 0)
        check("foreground activation is suppressed", policy.suppressForeground(type: 13, subtype: 1, now: 1))
        check("foreground activation is acknowledged without claiming target deactivation", policy.foregroundActivated && !policy.targetDeactivated)
        check("target deactivation is suppressed", policy.suppressTarget(type: 13, subtype: 2, now: 1.01))
        check("restoration requires 100ms quiet after the final transition", !policy.ready(now: 1.05, restoredForeground: true, hasError: false) && policy.ready(now: 1.12, restoredForeground: true, hasError: false))
        policy.beginForegroundRestore(now: 2)
        check("new restoration clears both acknowledgements", !policy.foregroundActivated && !policy.targetDeactivated)
        check("quiet alone cannot replace restoration acknowledgements", !policy.ready(now: 3, restoredForeground: true, hasError: false))
        for subtype in [Int64(22), 23] {
            check("foreground appearance \(subtype) is suppressed", policy.suppressForeground(type: 13, subtype: subtype, now: 4))
            check("target appearance \(subtype) is suppressed", policy.suppressTarget(type: 13, subtype: subtype, now: 4))
        }
        check("target activation itself is delivered", !policy.suppressTarget(type: 13, subtype: 1, now: 5))
        check("target type20 is observed but delivered", !policy.suppressTarget(type: 20, subtype: 0, now: 5))
        check("target type19 is suppressed", policy.suppressTarget(type: 19, subtype: 0, now: 5))
        check("foreground type20 is acknowledged and suppressed", policy.suppressForeground(type: 20, subtype: 0, now: 5))
        check("foreign overflow subtype is not misread as activation", !policy.suppressForeground(type: 13, subtype: 65537, now: 6))
        for type in [UInt32(10), 11, 12] {
            check("foreign key type\(type) is redirected", FocusRestorationPolicy.redirect(type: type, sourcePID: 30, targetPID: 20, servicePID: 10, receiverPID: 20))
            check("service key type\(type) is never redirected", !FocusRestorationPolicy.redirect(type: type, sourcePID: 10, targetPID: 20, servicePID: 10, receiverPID: 20))
        }
        check("keys already addressed elsewhere are untouched", !FocusRestorationPolicy.redirect(type: 10, sourcePID: 30, targetPID: 40, servicePID: 10, receiverPID: 20))
        check("pointer events are not rerouted by the key filter", !FocusRestorationPolicy.redirect(type: 1, sourcePID: 30, targetPID: 20, servicePID: 10, receiverPID: 20))
        check("invalid source PID is not truncated", !FocusRestorationPolicy.redirect(type: 10, sourcePID: Int64.max, targetPID: 20, servicePID: 10, receiverPID: 20))
        print("ALL \(passed) SYNTHETIC FOCUS EVENT/STATE CHECKS PASSED")
    }
}
