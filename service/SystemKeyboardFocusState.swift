import Foundation

// Keyboard focus-steal state transitions. This value type
// describes decisions only: the persistent native tap/hosted recovery adapter
// is still separate from the temporary FocusRestoration transaction.
struct SystemKeyboardFocusState {
    enum Focus: Equatable {
        case regularApp(Int32)
        case viewService(appPID: Int32, servicePID: Int32?)
        var appPID: Int32 {
            switch self { case .regularApp(let pid), .viewService(let pid, _): return pid }
        }
        var isUnresolvedViewService: Bool {
            if case .viewService(_, nil) = self { return true }; return false
        }
    }
    struct Suppression: Equatable {
        let thiefPID: Int32
        let thiefAppPID: Int32
        let victimPID: Int32
        var releasedTheft = false
        var suppressedReturnEvent = false
    }
    enum Notification: Equatable { case lost(Int32), gained(Int32) }
    struct Change {
        let notifications: [Notification]
        let releaseTheft: Bool
        let inspectViewService: Bool
        fileprivate let updatesViewBridgeSuppression: Bool
    }
    private(set) var currentFocus: Focus
    private(set) var previousFocus: Focus?
    private(set) var suppression: Suppression?
    private(set) var lastViewBridgeFocusStealWasSuppressed = false
    init(focus: Focus) { currentFocus = focus }

    // Membership compares the mapped application PID, not the
    // service PID. Regular and view-service cases both exclude the current app.
    mutating func keyFocusTaken(thiefPID: Int32, thief: Focus, victimPID: Int32,
                               protectedApps: [Int32]) -> Bool {
        guard protectedApps.contains(thief.appPID), thief.appPID != currentFocus.appPID else {
            suppression = nil; return false
        }
        suppression = Suppression(thiefPID: thiefPID, thiefAppPID: thief.appPID, victimPID: victimPID)
        return true
    }

    // Suppress just the first return to the recorded victim.
    mutating func keyFocusReturned(to pid: Int32) -> Bool {
        guard var record = suppression, !record.suppressedReturnEvent, record.victimPID == pid else { return false }
        record.suppressedReturnEvent = true; suppression = record; return true
    }

    mutating func focusChanged(to focus: Focus, rawPID: Int32,
                               protectedApps: [Int32]) -> Change {
        let old = currentFocus
        previousFocus = old; currentFocus = focus
        var notifications: [Notification] = []
        if old.appPID != focus.appPID {
            for pid in protectedApps {
                let suppressed = suppression.map { !$0.releasedTheft && $0.thiefAppPID == pid } ?? false
                if !suppressed {
                    if pid == old.appPID { notifications.append(.lost(pid)) }
                    if pid == focus.appPID { notifications.append(.gained(pid)) }
                }
            }
        }
        var release = false, matchesThief = false
        if var record = suppression {
            if record.thiefPID == rawPID {
                matchesThief = true
                if !record.releasedTheft { release = true; record.releasedTheft = true; suppression = record }
            } else if record.victimPID != rawPID { suppression = nil }
        }
        // The remaining native branch inspects AX focused-process ancestry
        // before deciding whether to release or repair a hosted service.
        let inspect = !matchesThief && old.isUnresolvedViewService && focus.isUnresolvedViewService &&
            old.appPID != focus.appPID && protectedApps.contains(focus.appPID)
        return Change(notifications: notifications, releaseTheft: release, inspectViewService: inspect,
                      updatesViewBridgeSuppression: focus.isUnresolvedViewService)
    }

    mutating func completed(_ change: Change, releasedFocus: Bool) {
        if change.updatesViewBridgeSuppression { lastViewBridgeFocusStealWasSuppressed = releasedFocus }
    }

    // Receiving new-front for the thief ends its transaction.
    mutating func newFront(focusPID: Int32) -> Bool {
        if suppression?.thiefPID == focusPID { suppression = nil }
        return lastViewBridgeFocusStealWasSuppressed
    }

    // Invoked by the per-PID keyboard mask.
    func keyboardRecipient(sourcePID: Int64, targetPID: Int64, servicePID: Int32) -> Int32? {
        guard Int32(exactly: sourcePID) != nil, sourcePID != Int64(servicePID),
              let record = suppression, targetPID == Int64(record.thiefPID) else { return nil }
        return record.victimPID
    }
}
