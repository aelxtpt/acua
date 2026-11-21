import Foundation
private enum AppSnapshotRequestCheckFailure: Error { case stopped, admission, capture, format }
@MainActor private final class AppSnapshotRequestFixture: ControllerAppSnapshotRequestBackend {
    typealias Capture = Int; typealias Reply = String
    var trace: [String] = [], failure: AppSnapshotRequestCheckFailure?, blocked: URL?
    var captured: [Bool] = [], interruption = true, finished = false, jobs: [() -> Void] = []
    var admitted = false, observedCapture: Int?, captureEffects = 0
    func activate() { trace.append("activate") }
    func updateActiveCount() { trace.append("count") }
    func requireNotStopped() throws { trace.append("stopped"); if case .stopped = failure { throw AppSnapshotRequestCheckFailure.stopped } }
    func admitStateRequery() async throws { trace.append("admit"); admitted = true; if case .admission = failure { throw AppSnapshotRequestCheckFailure.admission } }
    func capture(disableAXDiffing: Bool) async throws -> Int {
        trace.append("capture"); captured.append(disableAXDiffing); captureEffects += 1
        if case .capture = failure { throw AppSnapshotRequestCheckFailure.capture }; return 73
    }
    func blockedURL(_ capture: Int) async -> URL? { trace.append("policy"); observedCapture = capture; return blocked }
    func clearInterruptionAfterRequery() { trace.append("clear"); interruption = false }
    func scheduleFinishedCursor() { trace.append("schedule"); jobs.append { self.trace.append("finished"); self.finished = true } }
    func reply(_ capture: Int) throws -> String { trace.append("reply"); if case .format = failure { throw AppSnapshotRequestCheckFailure.format }; return "reply:\(capture)" }
}

@MainActor enum AppSnapshotRequestChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        for disable in [false, true] {
            let f = AppSnapshotRequestFixture()
            let result = try await ControllerAppSnapshotRequest(backend: f).perform(disableAXDiffing: disable)
            check("complete request sequence disable=\(disable)", result == "reply:73" && f.trace == ["activate", "count", "stopped", "admit", "capture", "policy", "clear", "schedule", "reply"])
            check("capture forwards explicit diff option and checks returned snapshot disable=\(disable)", f.captured == [disable] && f.observedCapture == 73 && f.admitted)
            check("successful state requery clears interruption before response disable=\(disable)", !f.interruption && !f.finished && f.jobs.count == 1)
            f.jobs.removeFirst()()
            check("finished cursor runs as later scheduled work disable=\(disable)", f.finished && f.trace.suffix(2) == ["reply", "finished"])
        }
        for failure in [AppSnapshotRequestCheckFailure.stopped, .admission, .capture, .format] {
            let f = AppSnapshotRequestFixture(); f.failure = failure
            var failed = false
            do { _ = try await ControllerAppSnapshotRequest(backend: f).perform(disableAXDiffing: false) }
            catch let caught as AppSnapshotRequestCheckFailure { failed = String(describing: caught) == String(describing: failure) }
            let stage = String(describing: failure), format = stage == "format"
            let expectedLast = stage == "admission" ? "admit" : format ? "reply" : stage
            check("\(failure) failure stops later request phases and preserves error", failed && f.trace.last == expectedLast)
            check("\(failure) failure keeps interruption/finished ordering", f.interruption == !format && f.jobs.count == (format ? 1 : 0) && !f.finished)
        }
        for url in ["https://EXAMPLE.invalid/private?q=1#fragment", "file:///private/tmp/owned", "custom:owned"] {
            let f = AppSnapshotRequestFixture(); let expected = URL(string: url)!; f.blocked = expected
            var caught: URL?
            do { _ = try await ControllerAppSnapshotRequest(backend: f).perform(disableAXDiffing: true) }
            catch ControllerAppSnapshotRequestFailure.blockedURL(let actual) { caught = actual }
            check("policy-provided blocked URL remains exact \(url)", caught == expected && f.trace.last == "policy" && f.interruption && f.jobs.isEmpty)
            check("policy rejection does not roll back already published capture effects \(url)", f.captureEffects == 1)
        }
        do {
            let f = AppSnapshotRequestFixture()
            let task = Task { @MainActor in
                let cancelled = Task.isCancelled
                let result = try await ControllerAppSnapshotRequest(backend: f).perform(disableAXDiffing: false)
                return (cancelled, result)
            }
            task.cancel(); let (cancelled, result) = try await task.value
            check("request adds no cancellation check before successful providers", cancelled && result == "reply:73" && !f.interruption && f.jobs.count == 1)
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks,
            "actual_input_focus_capture_network_or_preferences": false,
            "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("AppSnapshot request: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
