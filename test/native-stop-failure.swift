import AppKit
import Foundation

// The production stop adapter is compiled unchanged against an owned manager
// boundary. Only the manager operation's outcome is controlled; its selected
// implementation and real per-instance queue are verified separately.
struct IPCApp: Sendable {
    let pid: Int32
    let bundleIdentifier: String
    let appPath: String
}
struct IPCAppState: Sendable {
    let active: Bool
    let currentApp: IPCApp?
}
final class ControllerNativeAppController: @unchecked Sendable {
    struct Owner: Sendable {
        struct Target: Sendable { let url: URL }
        let pid: Int32 = 7
        let bundleIdentifier = "owned.test"
        let applicationTarget = Target(url: URL(fileURLWithPath: "/owned/App.app"))
    }
    let owner = Owner()
    @MainActor func deactivate() {}
}
final class OwnedStopFailure: Error, @unchecked Sendable {}
@MainActor final class OwnedManager {
    final class Instance: Sendable { let controller = ControllerNativeAppController() }
    enum Outcome { case failure, missing, instance }
    let error = OwnedStopFailure()
    var outcome: Outcome = .failure
    var stopped: Set<String> = []
    var clears: [String] = []
    func stop(_ key: String, deactivate: @escaping @Sendable (ControllerNativeAppController) -> Void) async throws -> Instance? {
        stopped.insert(key)
        switch outcome {
        case .failure: throw error
        case .missing: return nil
        case .instance:
            let instance = Instance()
            deactivate(instance.controller)
            return instance
        }
    }
    func clearStoppedByUser(for key: String) {
        clears.append(key)
        stopped.remove(key)
    }
}
@MainActor enum ControllerNativeInstanceBindings { typealias Manager = OwnedManager }
@MainActor struct ControllerNativeApplicationLifecycle {
    struct Bindings { let manager: OwnedManager }
    let bindings: Bindings
}

@main enum StopFailureChecks {
    @MainActor static func main() async throws {
        let manager = OwnedManager()
        let lifecycle = ControllerNativeApplicationLifecycle(bindings: .init(manager: manager))
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let raw = "  owned raw alias  "
        do {
            _ = try await lifecycle.stop(raw)
            check("queue error is returned", false)
        } catch {
            check("queue error identity is returned", (error as? OwnedStopFailure) === manager.error)
        }
        check("failed stop permits retry for the exact unnormalized identifier", !manager.stopped.contains(raw) && manager.clears == [raw])
        manager.outcome = .missing
        let missing = try await lifecycle.stop("")
        check("successful missing-target stop retains stopped state", !missing.active && missing.currentApp == nil && manager.stopped.contains(""))
        manager.outcome = .instance
        let known = try await lifecycle.stop("/owned/App.app")
        check("successful known-target stop retains state and response identity", !known.active && known.currentApp?.pid == 7 && known.currentApp?.bundleIdentifier == "owned.test" && known.currentApp?.appPath == "/owned/App.app" && manager.stopped.contains("/owned/App.app"))
        check("successful stops do not clear their stopped state", manager.clears == [raw])
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks,
            "actual_production_stop_adapter_compiled": true, "manager_outcome_boundary_controlled": true,
            "physical_input_or_native_focus_issued": false, "whole_service_error_path_paired": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Stop failure cleanup: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        exit(passed ? 0 : 3)
    }
}
