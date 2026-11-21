import Foundation

private final class PowerObservation {
    var creates = 0
    var releases = [UInt32]()
    var failed = false
}

@inline(never) private func exercisePower(_ row: [String: Any], _ observation: PowerObservation) -> [String: Any] {
    let status = (row["createStatus"] as! NSNumber).int32Value
    let id = (row["assertionID"] as! NSNumber).uint32Value
    let activity = RequestActivity(provider: .init(create: { kind, output in
        guard kind == .remoteUserActivity else { return -99 }
        observation.creates += 1; output = id; return status
    }, release: { value in
        observation.releases.append(value)
        return (row["releaseStatus"] as! NSNumber).int32Value
    }, failed: { kind, _ in if kind == .remoteUserActivity { observation.failed = true } }))
    var lease = activity.begin(RequestPreparation(requestType: "ComputerUseIPCAppPerformActionRequest"))
    let before = observation.releases
    if row["cancelExplicitly"] as! Bool { lease?.cancel(); lease?.cancel() }
    let after = withExtendedLifetime(lease) { observation.releases }
    lease = nil
    return ["createCalls": observation.creates, "accepted": !observation.failed,
            "beforeCancel": before, "afterCancel": after]
}

@main enum RequestActivityTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var results = [[String: Any]]()
        func check(_ ok: Bool, _ name: String) {
            results.append(["name": name, "passed": ok])
            print("\(ok ? "PASS" : "FAIL") request activity \(name)")
        }
        for row in expected["requestTraits"] as! [[String: Any]] {
            let type = row["requestType"] as! String
            let plan = RequestPreparation(requestType: type)
            let usage = row["appUsage"] as! Bool, exempt = row["exempt"] as! Bool
            check(plan.isAppUsage == usage && plan.holdsActivity == (!exempt && !type.contains("AppPolicyRequest")),
                  "runtime traits: \(type)")
            let turns = usage || ["ComputerUseIPCListAppsRequest", "ComputerUseIPCStartAudioRecordingRequest",
                                  "ComputerUseIPCStopAudioRecordingRequest"].contains(type)
            check(plan.preparesAgentTurn == turns && plan.decodesBeforePreparation == (usage || plan.isPolicy),
                  "dispatcher ordering: \(type)")
        }
        let preparation = RequestPreparation(requestType: "ComputerUseIPCAppPerformActionRequest")
        for row in expected["power"] as! [[String: Any]] {
            let observation = PowerObservation()
            var observed = exercisePower(row, observation)
            observed["afterDeinit"] = observation.releases
            let keys = ["createCalls", "accepted", "beforeCancel", "afterCancel", "afterDeinit"]
            let matches = keys.allSatisfy { NSDictionary(dictionary: ["value": observed[$0]!]) == NSDictionary(dictionary: ["value": row[$0]!]) }
            check(matches, "PowerAssertion callbacks: \(row["name"]!)")
            results[results.count - 1]["observed"] = observed
        }
        let statuses: [(Int32, UInt32)] = [(0, 101), (0, 0), (-1, 0), (-2, 103)]
        for (firstIndex, first) in statuses.enumerated() {
            for (secondIndex, second) in statuses.enumerated() {
                var creates = [RequestActivity.Kind](), failures = [RequestActivity.Kind](), releases = [UInt32]()
                let activity = RequestActivity(provider: .init(create: { kind, id in
                    creates.append(kind)
                    let value = kind == .remoteUserActivity ? first : second
                    id = value.1; return value.0
                }, release: { releases.append($0); return -9 }, failed: { failures.append($0); _ = $1 }))
                let lease = activity.begin(preparation)
                let expectedReleases = [first, second].filter { $0.0 == 0 && $0.1 != 0 }.map { $0.1 }.reversed()
                let expectedFailures = zip(RequestActivity.Kind.allCases, [first, second]).filter {
                    $0.1.0 != 0 || $0.1.1 == 0
                }.map { $0.0 }
                check(creates == RequestActivity.Kind.allCases && releases.isEmpty && failures == expectedFailures,
                      "both acquisitions are independent \(firstIndex)-\(secondIndex)")
                lease?.cancel(); lease?.cancel()
                check(releases == Array(expectedReleases), "reverse, once-only release \(firstIndex)-\(secondIndex)")
            }
        }
        var unneededCalls = 0
        let forbidden = RequestActivity(provider: .init(create: { _, _ in unneededCalls += 1; return 0 },
                                                     release: { _ in unneededCalls += 1; return 0 }))
        for row in expected["requestTraits"] as! [[String: Any]] {
            let plan = RequestPreparation(requestType: row["requestType"] as! String)
            if !plan.holdsActivity { check(forbidden.begin(plan) == nil, "exemption has no provider calls: \(plan.requestType)") }
        }
        check(unneededCalls == 0, "exempt and policy requests do not call power providers")
        check(RequestPreparation(requestType: "ComputerUseIPCMessagesFutureRequest").holdsActivity &&
              RequestPreparation(requestType: "ComputerUseIPCTimelineStatusRequest-extra").holdsActivity,
              "unknown and similarly named types do not inherit an exemption")

        let lock = NSLock()
        var released = [UInt32]()
        let concurrent = RequestActivity(provider: .init(create: { kind, id in
            id = kind == .remoteUserActivity ? 81 : 82; return 0
        }, release: { id in lock.withLock { released.append(id) }; return 0 }))
        let shared = concurrent.begin(preparation)!
        DispatchQueue.concurrentPerform(iterations: 128) { _ in shared.cancel() }
        check(released == [82, 81], "128 concurrent cancellations release each assertion once")

        var reentrant: RequestActivity.Lease?, reentrantIDs = [UInt32]()
        let reentry = RequestActivity(provider: .init(create: { kind, id in
            id = kind == .remoteUserActivity ? 91 : 92; return 0
        }, release: { id in reentrantIDs.append(id); reentrant?.cancel(); return 0 }))
        reentrant = reentry.begin(preparation)
        reentrant?.cancel(); reentrant = nil
        check(reentrantIDs == [92, 91], "release callbacks may reenter cancellation without deadlock")
        let one = concurrent.begin(preparation)!, two = concurrent.begin(preparation)!
        released.removeAll(); one.cancel()
        check(released == [82, 81], "one request cannot release a second request's lease")
        two.cancel()
        check(released == [82, 81, 82, 81], "each overlapping request retains independent ownership")

        let report: [String: Any] = ["cases": results.count, "passed": results.allSatisfy { $0["passed"] as? Bool == true },
                                   "results": results, "native_UI": false, "realPowerAPICalled": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if report["passed"] as? Bool != true { exit(1) }
    }
}
