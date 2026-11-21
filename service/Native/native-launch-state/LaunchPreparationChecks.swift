import Foundation

private enum LaunchCheckFailure: Error { case open, sleep, settle }
@MainActor private final class LaunchPreparationFixture: ControllerLaunchPreparationBackend {
    typealias Target = String; typealias Application = Int; typealias Node = Int
    var existing: Int? = nil, minimizedValue: Bool? = nil
    var windows: [Int: [Int?]] = [2: [22]]
    var dates: [TimeInterval] = [], time: TimeInterval = 0
    var sleeps: [Duration] = [], trace: [String] = [], settled: (Int, Double, Double, Bool)?
    var failure: LaunchCheckFailure?, onSleep: (() -> Void)?
    func running(_ target: String) -> Int? { trace.append("running:\(target)"); return existing }
    func node(_ application: Int) -> Int { trace.append("node:\(application)"); return application }
    func primaryWindow(_ application: Int) -> Int? {
        trace.append("primary:\(application)")
        guard var values = windows[application], !values.isEmpty else { return nil }
        let value = values.removeFirst(); windows[application] = values; return value
    }
    func minimized(_ window: Int) -> Bool? { trace.append("minimized:\(window)"); return minimizedValue }
    func open(_ target: String) async throws -> Int { trace.append("open:\(target)"); if case .open = failure { throw LaunchCheckFailure.open }; return 2 }
    func now() -> Date { trace.append("now"); if !dates.isEmpty { return Date(timeIntervalSince1970: dates.removeFirst()) }; return Date(timeIntervalSince1970: time) }
    func sleep(_ interval: Duration) async throws { trace.append("sleep"); sleeps.append(interval); if case .sleep = failure { throw LaunchCheckFailure.sleep }; time += 0.05; onSleep?() }
    func settle(_ application: Int, delay: Double, notificationDelay: Double, scroll: Bool) async throws {
        trace.append("settle"); settled = (application, delay, notificationDelay, scroll)
        if case .settle = failure { throw LaunchCheckFailure.settle }
    }
}

@MainActor enum LaunchPreparationChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        for minimized: Bool? in [nil, false] {
            let f = LaunchPreparationFixture(); f.existing = 1; f.windows[1] = [11]; f.minimizedValue = minimized
            try await ControllerLaunchPreparation(backend: f).prepare("target")
            check("existing primary minimized=\(String(describing: minimized)) bypasses opening and settling", f.trace == ["running:target", "node:1", "primary:1", "minimized:11"] && f.settled == nil)
        }
        for existing: Int? in [nil, 1] {
            let f = LaunchPreparationFixture(); f.existing = existing
            try await ControllerLaunchPreparation(backend: f).prepare("target")
            check("missing running/window \(String(describing: existing)) opens before new app wrapper and poll", f.trace.first == "running:target" && f.trace.firstIndex(of: "open:target")! < f.trace.firstIndex(of: "node:2")! && f.trace.contains("primary:2"))
            check("launch settle \(String(describing: existing)) uses the newly opened app and exact delays", f.settled?.0 == 2 && f.settled?.1 == 0.05 && f.settled?.2 == 0.25 && f.settled?.3 == false && f.sleeps.isEmpty)
        }
        do {
            let f = LaunchPreparationFixture(); f.existing = 1; f.windows[1] = [11]; f.minimizedValue = true
            try await ControllerLaunchPreparation(backend: f).prepare("target")
            check("minimized existing window reopens target and settles returned application", f.trace.contains("minimized:11") && f.trace.contains("open:target") && f.settled?.0 == 2)
        }
        do {
            let f = LaunchPreparationFixture(); f.windows[2] = [nil, nil, 22]
            try await ControllerLaunchPreparation(backend: f).prepare("target")
            check("poll repeats primary reads and sleeps continuous fifty milliseconds", f.sleeps == [.milliseconds(50), .milliseconds(50)] && f.trace.filter { $0 == "primary:2" }.count == 3 && f.trace.last == "settle")
        }
        for failure in [LaunchCheckFailure.open, .sleep, .settle] {
            let f = LaunchPreparationFixture(); f.failure = failure
            if case .sleep = failure { f.windows[2] = [nil, 22] }
            var caught = false
            do { try await ControllerLaunchPreparation(backend: f).prepare("target") }
            catch let actual as LaunchCheckFailure { caught = String(describing: actual) == String(describing: failure) }
            let last = String(describing: failure) == "open" ? "open:target" : String(describing: failure)
            check("\(failure) failure propagates without later launch stages", caught && f.trace.last == last)
        }
        do {
            let f = LaunchPreparationFixture(); f.dates = [0, 5]
            check("condition at exact five-second timeout is still evaluated", try await ControllerLaunchPreparation(backend: f).primaryWindow(2, timeout: 5, pollingInterval: 0.05) == 22 && f.sleeps.isEmpty)
        }
        for timeout in [5.0, -1.0] {
            let f = LaunchPreparationFixture(); f.dates = [0, timeout == 5 ? 5.0001 : 0]
            var caught = false
            do { _ = try await ControllerLaunchPreparation(backend: f).primaryWindow(2, timeout: timeout, pollingInterval: 0.05) }
            catch SystemSettingsPollError.timeoutReached { caught = true }
            check("elapsed exceeds \(timeout) before primary read", caught && !f.trace.contains("primary:2") && f.sleeps.isEmpty)
        }
        do {
            let f = LaunchPreparationFixture(); f.windows[2] = [nil, 22]; f.time = 10
            f.onSleep = { f.time = 9 }
            check("wall-clock rollback extends polling rather than replacing it with monotonic timeout", try await ControllerLaunchPreparation(backend: f).primaryWindow(2, timeout: 0, pollingInterval: 0.05) == 22 && f.sleeps == [.milliseconds(50)])
        }
        do {
            let f = LaunchPreparationFixture(); f.windows[2] = [nil, 22]; f.dates = [0, 0, 6]
            var caught = false
            do { _ = try await ControllerLaunchPreparation(backend: f).primaryWindow(2, timeout: 5, pollingInterval: 0.05) }
            catch SystemSettingsPollError.timeoutReached { caught = true }
            check("overshooting sleep does not add a final condition read", caught && f.trace.filter { $0 == "primary:2" }.count == 1 && f.sleeps.count == 1)
        }
        do {
            let f = LaunchPreparationFixture()
            let task = Task { @MainActor in
                let cancelled = Task.isCancelled
                let result = try await ControllerLaunchPreparation(backend: f).primaryWindow(2, timeout: 5, pollingInterval: 0.05)
                return (cancelled, result)
            }
            task.cancel(); let (cancelled, result) = try await task.value
            check("already cancelled caller still succeeds on first available primary without invented checkpoint", cancelled && result == 22 && f.sleeps.isEmpty)
        }
        let error = SystemSettingsPollError.timeoutReached as NSError
        check("primary timeout retains shared PollError NSError domain and code", error.domain == "AccessibilitySupport.PollError" && error.code == 0 && error.userInfo.isEmpty)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks,
            "actual_application_launch_input_focus_capture_or_preferences": false,
            "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Launch preparation: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
