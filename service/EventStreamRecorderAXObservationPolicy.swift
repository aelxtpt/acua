import Foundation

// Native observer setup, notification list, terminal membership and
// observation delay.
enum EventStreamRecorderAXObservationPolicy {
    static let baseNotifications = [
        "AXFocusedWindowChanged", "AXSelectedRowsChanged", "AXSelectedColumnsChanged",
        "AXSelectedTextChanged", "AXSelectedChildrenChanged", "AXSelectedChildrenMoved",
        "AXSelectedCellsChanged"
    ]
    static let ignoredRegistrationErrors: Set<Int32> = [-25204, -25207]

    static func notifications(bundleIdentifier: String?, terminalBundleIdentifiers: [String]) -> [String] {
        guard let bundleIdentifier, terminalBundleIdentifiers.contains(bundleIdentifier) else { return baseNotifications }
        return baseNotifications + ["AXValueChanged"]
    }

    static func acceptsRegistration(_ status: Int32) -> Bool {
        status == 0 || status == -25209 || ignoredRegistrationErrors.contains(status)
    }

    static func debounceMilliseconds(notification: String) -> Int {
        notification == "AXSelectedTextChanged" ? 500 : 250
    }
}
