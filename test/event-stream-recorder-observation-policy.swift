import Foundation

@main struct Tests {
    static func main() {
        var checks = 0
        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), "FAIL: \(label)"); checks += 1; print("PASS: \(label)")
        }
        typealias P = EventStreamRecorderAXObservationPolicy
        let ids = ["com.apple.Terminal", "com.example.terminal"]
        let basic = ["AXFocusedWindowChanged", "AXSelectedRowsChanged", "AXSelectedColumnsChanged", "AXSelectedTextChanged", "AXSelectedChildrenChanged", "AXSelectedChildrenMoved", "AXSelectedCellsChanged"]
        check("ordinary applications use the seven default notifications in order", P.notifications(bundleIdentifier: "com.example.editor", terminalBundleIdentifiers: ids) == basic)
        check("terminal app appends value changes", P.notifications(bundleIdentifier: "com.apple.Terminal", terminalBundleIdentifiers: ids) == basic + ["AXValueChanged"])
        check("missing bundle does not add value observation", P.notifications(bundleIdentifier: nil, terminalBundleIdentifiers: ids) == basic)
        check("terminal match is not a prefix", P.notifications(bundleIdentifier: "com.apple.Terminal.extra", terminalBundleIdentifiers: ids) == basic)
        check("terminal match preserves case", P.notifications(bundleIdentifier: "com.apple.terminal", terminalBundleIdentifiers: ids) == basic)
        check("terminal match retains Swift canonical string equality", P.notifications(bundleIdentifier: "com.cafe\u{301}", terminalBundleIdentifiers: ["com.café"]) == basic + ["AXValueChanged"])
        check("empty terminal list uses base notifications", P.notifications(bundleIdentifier: "com.apple.Terminal", terminalBundleIdentifiers: []) == basic)
        check("repeated terminal IDs add value observation only once", P.notifications(bundleIdentifier: "x", terminalBundleIdentifiers: ["x", "x"]) == basic + ["AXValueChanged"])
        check("recorder tolerates cannot-complete registration", P.acceptsRegistration(-25204))
        check("recorder tolerates unsupported notification", P.acceptsRegistration(-25207))
        check("intrinsic already-registered is accepted", P.acceptsRegistration(-25209))
        check("successful registration is accepted", P.acceptsRegistration(0))
        check("invalid element and unsupported attribute are not ignored", !P.acceptsRegistration(-25202) && !P.acceptsRegistration(-25205))
        check("other observer failures propagate", !P.acceptsRegistration(-25200) && !P.acceptsRegistration(-25203) && !P.acceptsRegistration(-25208))
        check("text selection waits 500 milliseconds", P.debounceMilliseconds(notification: "AXSelectedTextChanged") == 500)
        check("other selections wait 250 milliseconds", basic.filter { $0 != "AXSelectedTextChanged" }.allSatisfy { P.debounceMilliseconds(notification: $0) == 250 })
        check("unknown notification keeps the 250 ms default delay", P.debounceMilliseconds(notification: "unknown") == 250)
        print("\(checks) checks")
    }
}
