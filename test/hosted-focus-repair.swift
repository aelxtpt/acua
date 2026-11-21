@main enum HostedFocusRepairTests {
    static func main() {
        var checks = 0
        func check(_ name: String, _ valid: Bool) {
            precondition(valid, name); checks += 1; print("PASS \(name)")
        }
        typealias Kind = HostedFocusRepair.ProcessKind
        for kind: Kind? in [nil, .application, .service] {
            for protected in [false, true] {
                for status in [false, true] {
                    var trace: [String] = []
                    var state = SystemKeyboardFocusState(focus: .viewService(appPID: 10, servicePID: nil))
                    let registrations: [Int32] = protected ? [10, 20] : [20]
                    let change = state.focusChanged(to: .viewService(appPID: 20, servicePID: nil), rawPID: 200,
                                                    protectedApps: registrations)
                    let result = HostedFocusRepair.perform(releaseTheft: change.releaseTheft,
                        inspectViewService: change.inspectViewService, previousAppPID: 10,
                        previousAppProtected: protected, focusedProcess: { trace.append("inspect:10"); return kind },
                        release: { trace.append("release-real-event-token"); return status },
                        repair: { trace.append("repair:\($0)") })
                    state.completed(change, releasedFocus: result)
                    let expected: [String]
                    let didRelease: Bool
                    switch kind {
                    case .application? where !protected:
                        expected = ["inspect:10", "release-real-event-token"]; didRelease = status
                    case .service? where !protected:
                        expected = ["inspect:10", "repair:10"]; didRelease = false
                    default: expected = ["inspect:10"]; didRelease = false
                    }
                    check("cross-host branch kind=\(String(describing: kind)) oldProtected=\(protected) releaseStatus=\(status)",
                          trace == expected && result == didRelease && state.lastViewBridgeFocusStealWasSuppressed == didRelease &&
                          change.notifications == (protected ? [.lost(10), .gained(20)] : [.gained(20)]))
                }
            }
        }
        for status in [false, true] {
            var trace: [String] = []
            var state = SystemKeyboardFocusState(focus: .viewService(appPID: 10, servicePID: nil))
            _ = state.keyFocusTaken(thiefPID: 200, thief: .viewService(appPID: 20, servicePID: 200),
                                    victimPID: 10, protectedApps: [20])
            let change = state.focusChanged(to: .viewService(appPID: 20, servicePID: nil), rawPID: 200, protectedApps: [20])
            let result = HostedFocusRepair.perform(releaseTheft: change.releaseTheft,
                inspectViewService: change.inspectViewService, previousAppPID: 10, previousAppProtected: false,
                focusedProcess: { trace.append("unexpected-inspection"); return .service },
                release: { trace.append("release"); return status }, repair: { trace.append("unexpected-repair:\($0)") })
            state.completed(change, releasedFocus: result)
            check("recorded theft releases once without hosted inspection, status=\(status)", trace == ["release"] && result == status)
            let repeated = state.focusChanged(to: .viewService(appPID: 20, servicePID: nil), rawPID: 200, protectedApps: [20])
            trace = []
            _ = HostedFocusRepair.perform(releaseTheft: repeated.releaseTheft,
                inspectViewService: repeated.inspectViewService, previousAppPID: 20, previousAppProtected: true,
                focusedProcess: { trace.append("unexpected-inspection"); return nil },
                release: { trace.append("unexpected-release"); return true }, repair: { trace.append("unexpected-repair:\($0)") })
            check("repeated theft does not retry even a failed release, status=\(status)", trace.isEmpty)
        }
        print("\(checks) hosted focus repair branch checks passed")
    }
}
