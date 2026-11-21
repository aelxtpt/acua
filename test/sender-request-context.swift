import Foundation

@main enum SenderRequestContextTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var results = [[String: Any]]()
        func check(_ passed: Bool, _ name: String) {
            results.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") sender context \(name)")
        }
        let ownTeam = expected["ownTeam"] as! String
        let hostBundle = expected["hostBundleIdentifier"] as! String
        let parent = SenderProcessIdentity(team: ownTeam, signingID: hostBundle + ".client", bundleID: hostBundle + ".client")
        check(AcuaOwnIdentity.bundleIdentifier == hostBundle &&
              AcuaOwnIdentity.isOwnBundleIdentifier((expected["hostBundleChildPrefix"] as! String) + "client"),
              "own host bundle identifier and child prefix")
        for row in expected["cases"] as! [[String: Any]] {
            let responsible: SenderProcessIdentity? = row["responsiblePresent"] as? Bool == true
                ? .init(team: row["team"] as? String, signingID: row["signingID"] as? String,
                        bundleID: row["bundleID"] as? String, executable: row["executable"] as? String) : nil
            let context = SenderRequestContext(senderPID: 41, responsibleIdentity: responsible, ancestorIdentities: [parent])
            check(context.allowsLockScreenAutoUnlock(ownTeam: ownTeam) == row["allows"] as? Bool,
                  "auto-unlock predicate: \(row["name"]!)")
        }
        let ownHost = SenderRequestContext(senderPID: 41, responsibleIdentity: parent, ancestorIdentities: [parent])
        check(ownHost.allowsLockScreenAutoUnlock(ownTeam: ownTeam) && !ownHost.allowsLockScreenAutoUnlock(ownTeam: nil) &&
              !ownHost.allowsLockScreenAutoUnlock(ownTeam: "OTHERTEAM1"),
              "auto-unlock requires the service's own team to be known and to match")
        var trace = [String](), phase = "first"
        let resolver = SenderRequestContext.Resolver(ancestorPIDs: { pid in
            trace.append("ancestors:\(pid)"); return [51, 61]
        }, identity: { pid in
            trace.append("identity:\(pid)")
            return .init(team: ownTeam, bundleID: pid == 71 ? phase : "parent-\(pid)")
        }, responsiblePID: { pid in trace.append("responsible:\(pid)"); return 71 })
        let snapshot = resolver.resolve(41)!
        check(trace == ["ancestors:41", "identity:51", "identity:61", "responsible:41", "identity:71"],
              "ancestor/parent/responsible resolution order")
        check(snapshot.senderPID == 41 && snapshot.parentIdentity?.bundleID == "parent-51" &&
              snapshot.ancestorIdentities.map(\.bundleID) == ["parent-51", "parent-61"] &&
              snapshot.responsibleIdentity?.bundleID == "first", "complete identity snapshot")
        phase = "replacement"
        check(snapshot.responsibleIdentity?.bundleID == "first" && resolver.resolve(41)?.responsibleIdentity?.bundleID == "replacement",
              "an existing snapshot is stable and a new resolution refreshes it")
        trace.removeAll()
        check(resolver.resolve(0) == nil && resolver.resolve(-1) == nil && trace.isEmpty,
              "invalid peer IDs perform no resolution")
        for responsiblePID: Int32? in [nil, 0, -1] {
            var queried = [Int32]()
            let absent = SenderRequestContext.Resolver(ancestorPIDs: { _ in [] }, identity: {
                queried.append($0); return parent
            }, responsiblePID: { _ in responsiblePID }).resolve(41)!
            check(absent.parentIdentity == nil && absent.responsibleIdentity == nil && queried.isEmpty &&
                  !absent.allowsLockScreenAutoUnlock(ownTeam: ownTeam), "missing/invalid responsibility fails closed: \(String(describing: responsiblePID))")
        }
        let trusted = SenderRequestContext(senderPID: 41, responsibleIdentity: parent, ancestorIdentities: [parent])
            .withAppleEventMetadata(clientType: "snapshot-client", version: SenderClientMetadata.nativeBridgeVersion)
        let other = SenderRequestContext(senderPID: 42, responsibleIdentity: .init(team: "OTHERTEAM1", bundleID: "com.example.agent"), ancestorIdentities: [])
        var worker: RequestRuntime.WorkerScope?
        var clientCancelled = false
        check(RequestRuntime.peerPID == nil && RequestRuntime.senderContext == nil, "no identity outside a request")
        try RequestRuntime.withRequest([:], cancelled: { clientCancelled }, peerPID: 41, senderContext: trusted) {
            check(RequestRuntime.peerPID == 41 && RequestRuntime.senderContext == trusted, "request installs its matching identity")
            try RequestRuntime.withRequest([:]) {
                check(RequestRuntime.senderContext == trusted, "nested work inherits the same peer snapshot")
            }
            try RequestRuntime.withRequest([:], peerPID: 41) {
                check(RequestRuntime.senderContext == trusted, "same explicit peer inherits its snapshot")
            }
            try RequestRuntime.withRequest([:], peerPID: 42) {
                check(RequestRuntime.peerPID == 42 && RequestRuntime.senderContext == nil,
                      "a different peer cannot inherit an outer identity")
            }
            try RequestRuntime.withRequest([:], peerPID: 42, senderContext: trusted) {
                check(RequestRuntime.senderContext == nil, "a mismatched internal context is discarded")
            }
            try RequestRuntime.withRequest([:], senderContext: other) {
                check(RequestRuntime.peerPID == 42 && RequestRuntime.senderContext == other,
                      "an explicit replacement context establishes its own peer")
            }
            check(RequestRuntime.peerPID == 41 && RequestRuntime.senderContext == trusted, "nested replacement restores the parent")
            try RequestRuntime.withCheckpoint({}) {
                check(RequestRuntime.senderContext == trusted, "session checkpoints preserve sender identity")
            }
            worker = RequestRuntime.workerScope()
        }
        check(RequestRuntime.senderContext == nil && RequestRuntime.peerPID == nil, "normal return clears request identity")
        clientCancelled = true
        try RequestRuntime.withWorkerScope(worker!, cancelled: { false }) {
            check(RequestRuntime.peerPID == 41 && RequestRuntime.senderContext == trusted,
                  "a detached worker retains identity without retaining client cancellation")
        }
        check(RequestRuntime.senderContext == nil, "worker return restores prior identity")
        do {
            try RequestRuntime.withRequest([:], peerPID: 41, senderContext: trusted) {
                throw ServiceError(.unknownError, "owned fixture failure")
            }
        } catch {}
        check(RequestRuntime.senderContext == nil && RequestRuntime.peerPID == nil, "throwing work clears identity")
        var enteredCancelled = false
        do {
            try RequestRuntime.withRequest([:], cancelled: { true }, peerPID: 41, senderContext: trusted) { enteredCancelled = true }
        } catch {}
        check(!enteredCancelled && RequestRuntime.senderContext == nil, "initial cancellation restores identity before handler entry")

        let lock = NSLock()
        var concurrentMatches = 0
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let identity = SenderRequestContext(senderPID: Int32(1000 + index), responsibleIdentity: .init(bundleID: "owner-\(index)"), ancestorIdentities: [])
            do {
                try RequestRuntime.withRequest([:], senderContext: identity) {
                    let retained = RequestRuntime.workerScope()
                    try RequestRuntime.withWorkerScope(retained, cancelled: { false }) {
                        if RequestRuntime.senderContext == identity && RequestRuntime.peerPID == identity.senderPID {
                            lock.withLock { concurrentMatches += 1 }
                        }
                    }
                }
            } catch {}
        }
        check(concurrentMatches == 64, "64 concurrent request/worker scopes keep independent identities")
        final class Transfer: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            var passed = false
            func finish(_ value: Bool) { lock.withLock { passed = value; done = true } }
        }
        let transfer = Transfer()
        DispatchQueue.global().async {
            do {
                let value = try RequestRuntime.withRequest([:], senderContext: trusted) {
                    try RequestRuntime.onMainThread { Thread.isMainThread && RequestRuntime.senderContext == trusted && RequestRuntime.peerPID == 41 }
                }
                transfer.finish(value)
            } catch { transfer.finish(false) }
        }
        let until = Date().addingTimeInterval(3)
        while !transfer.lock.withLock({ transfer.done }) && Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(transfer.lock.withLock { transfer.done && transfer.passed }, "main-thread handoff carries the same context")
        check(RequestRuntime.peerPID == nil && RequestRuntime.senderContext == nil, "main-thread handoff restores its previous scope")
        let report: [String: Any] = ["cases": results.count, "passed": results.allSatisfy { $0["passed"] as? Bool == true },
            "results": results, "predicateCases": (expected["cases"] as! [Any]).count,
            "native_UI": false, "actualUnlock": false, "nativeIdentityResolution": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if report["passed"] as? Bool != true { exit(1) }
    }
}
