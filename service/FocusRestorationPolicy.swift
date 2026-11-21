import Foundation

// Foreground and target tap decisions. Time is supplied by the observer,
// keeping the policy independently testable.
struct FocusRestorationPolicy {
    private(set) var sawActivity = false
    private(set) var foregroundActivated = false
    private(set) var targetDeactivated = false
    private(set) var lastChange: Double
    init(now: Double) { lastChange = now }

    mutating func suppressForeground(type: UInt32, subtype: Int64, now: Double) -> Bool {
        lastChange = now
        if type == 20 || (type == 13 && subtype == 1) {
            sawActivity = true; foregroundActivated = true; return true
        }
        if type == 19 || (type == 13 && subtype == 2) { sawActivity = true; return true }
        return type == 13 && (subtype == 22 || subtype == 23)
    }
    mutating func suppressTarget(type: UInt32, subtype: Int64, now: Double) -> Bool {
        lastChange = now
        if type == 20 { sawActivity = true; return false }
        if type == 19 || (type == 13 && subtype == 2) {
            sawActivity = true; targetDeactivated = true; return true
        }
        return type == 13 && (subtype == 22 || subtype == 23)
    }
    mutating func beginForegroundRestore(now: Double) {
        foregroundActivated = false; targetDeactivated = false; lastChange = now
    }
    mutating func windowRaised(now: Double) { lastChange = now }
    func ready(now: Double, restoredForeground: Bool, hasError: Bool) -> Bool {
        if restoredForeground && (!foregroundActivated || !targetDeactivated) { return false }
        return !(sawActivity || restoredForeground || hasError) || now - lastChange >= 0.1
    }

    // The target-head tap only intercepts keys and modifier changes.
    static func redirect(type: UInt32, sourcePID: Int64, targetPID: Int64,
                         servicePID: Int32, receiverPID: Int32) -> Bool {
        [UInt32(10), 11, 12].contains(type) && sourcePID != Int64(servicePID) &&
            Int32(exactly: sourcePID) != nil && targetPID == Int64(receiverPID)
    }
}
