import Foundation
import Darwin

@main enum AppleEventAuthorizationTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var results = [[String: Any]]()
        func check(_ ok: Bool, _ name: String) {
            results.append(["name": name, "passed": ok]); print("\(ok ? "PASS" : "FAIL") Apple Event auth \(name)")
        }
        let ownTeamID = expected["ownTeam"] as! String
        let foreignTeamID = "OTHERTEAM1"
        let trusted = SenderProcessIdentity(team: ownTeamID)
        func context(_ pid: Int32) -> SenderRequestContext { .init(senderPID: pid, responsibleIdentity: nil, ancestorIdentities: [trusted]) }
        // Role and provider-order cases: each trace lists the provider calls in
        // the order the policy makes them.
        func run(_ name: String, pid: Int32? = 41, own: String? = ownTeamID, audit: String? = nil,
                 process: String? = nil, version: String? = nil, host: Bool = false, allowed: Bool = false,
                 expectedRole: Bool?, failure: AppleEventAuthorization.Failure? = nil, trace expectedTrace: [String]) {
            var trace = [String]()
            let policy = AppleEventAuthorization(providers: .init(ownTeam: { trace.append("own"); return own },
                auditMatches: { _, team in trace.append("audit:\(team)"); return audit == team },
                processMatches: { _, team in trace.append("pid:\(team)"); return process == team },
                isDesignatedHost: { _ in trace.append("host"); return host },
                resolveContext: { pid in trace.append("resolve"); return context(pid) },
                contextAllowed: { _ in trace.append("context"); return allowed }))
            var role: Bool?, observed: AppleEventAuthorization.Failure?
            do { role = try policy.authorize(.init(pid: pid, auditData: audit == nil ? nil : Data([1]), version: version)).foregroundOnly }
            catch { observed = error as? AppleEventAuthorization.Failure }
            check(role == expectedRole && observed == failure && trace == expectedTrace, name)
        }
        let ownAudit = "audit:\(ownTeamID)", ownPID = "pid:\(ownTeamID)"
        run("missing PID precedes all providers", pid: nil, expectedRole: nil, failure: .missingSenderPID, trace: [])
        run("missing own team precedes an own-team audit match", own: nil, audit: ownTeamID, expectedRole: nil, failure: .teamNotFound, trace: ["own"])
        run("audit match avoids PID lookup", audit: ownTeamID, allowed: true, expectedRole: false,
            trace: ["own",ownAudit,"resolve","context"])
        run("failed audit falls back to PID", audit: foreignTeamID, process: ownTeamID, allowed: true, expectedRole: false,
            trace: ["own",ownAudit,ownPID,"resolve","context"])
        run("absent audit uses own-team PID", process: ownTeamID, allowed: true, expectedRole: false,
            trace: ["own",ownPID,"resolve","context"])
        run("own-team process without a trusted context receives subscription-only access", process: ownTeamID, expectedRole: true,
            trace: ["own",ownPID,"resolve","context",ownPID])
        run("own-team audit without an own-team PID cannot get restricted access", audit: ownTeamID, process: foreignTeamID,
            expectedRole: nil, failure: .notAuthenticated, trace: ["own",ownAudit,"resolve","context",ownPID])
        run("foreign-team signature never resolves context", process: foreignTeamID, allowed: true, expectedRole: nil, failure: .notAuthenticated,
            trace: ["own",ownPID])
        run("foreign-team audit never resolves context", audit: foreignTeamID, allowed: true, expectedRole: nil, failure: .notAuthenticated,
            trace: ["own",ownAudit,ownPID])
        run("team identifiers remain case sensitive", process: ownTeamID.lowercased(), allowed: true, expectedRole: nil, failure: .notAuthenticated,
            trace: ["own",ownPID])
        run("native bridge host bypasses ancestry after signature checks", process: ownTeamID, version: AppleEventAuthorization.nativeBridgeVersion, host: true, expectedRole: false,
            trace: ["own",ownPID,"host",ownPID,"resolve"])
        run("native bridge name alone does not replace PID signature", audit: ownTeamID, process: foreignTeamID, version: AppleEventAuthorization.nativeBridgeVersion,
            host: true, expectedRole: nil, failure: .notAuthenticated,
            trace: ["own",ownAudit,"host",ownPID,"resolve","context",ownPID])
        run("non-host native client can receive only restricted access", process: ownTeamID, version: AppleEventAuthorization.nativeBridgeVersion,
            expectedRole: true, trace: ["own",ownPID,"host","resolve","context",ownPID])
        run("version case change does not invoke host exception", process: ownTeamID, version: "acuacomputerusenativebridge-1", host: true,
            expectedRole: true, trace: ["own",ownPID,"resolve","context",ownPID])

        let trustedTeams = expected["trustedTeams"] as! [String]
        for row in expected["cases"] as! [[String: Any]] where row["teams"] as! [String] == trustedTeams {
            for contextAllowed in [false, true] {
                let pidTeam = row["pidTeam"] as? String
                let bundle = row["bundle"] as? String
                let policy = AppleEventAuthorization(providers: .init(ownTeam: { ownTeamID }, auditMatches: { _, _ in false },
                    processMatches: { _, team in pidTeam == team },
                    isDesignatedHost: { _ in bundle.map(AcuaOwnIdentity.isOwnBundleIdentifier) ?? false },
                    resolveContext: { context($0) }, contextAllowed: { _ in contextAllowed }))
                var role: Bool?, denied = false
                do { role = try policy.authorize(.init(pid: (row["pid"] as! NSNumber).int32Value,
                    auditData: row["audit"] as! String == "absent" ? nil : Data(repeating: 255, count: row["audit"] as! String == "short" ? 31 : 32),
                    version: row["version"] as? String)).foregroundOnly }
                catch { denied = error as? AppleEventAuthorization.Failure == .notAuthenticated }
                let signature = row["signature"] as! Bool, bridge = row["bridge"] as! Bool
                let expectedRole: Bool? = !signature ? nil : (bridge || contextAllowed ? false : true)
                check(role == expectedRole && denied == (expectedRole == nil),
                      "expected decision \(row["label"]!)-\(row["version"]!)-\(row["audit"]!)-context=\(contextAllowed)")
            }
        }
        var ownTeam: String? = ownTeamID, auditTeam: String? = ownTeamID, processTeam: String? = nil
        var audits = 0, processes = 0
        let adapter = SenderAuthorization(ownTeam: { ownTeam }, peerTeam: { _ in audits += 1; return auditTeam },
            ancestors: { _ in [] }, processTeam: { _ in processes += 1; return processTeam })
        let raw = Data(repeating: 1, count: 32)
        let sender = AppleEventAuthorization.Sender(pid: 41, auditData: raw, version: nil)
        _ = try adapter.authorizeAppleEventSignedClient(sender, resolveContext: { context($0) })
        auditTeam = nil
        _ = try adapter.authorizeAppleEventSignedClient(sender, resolveContext: { context($0) })
        check(audits == 1 && processes == 0, "adapter caches successful full audit identity only")
        ownTeam = nil
        do { _ = try adapter.authorizeAppleEventSignedClient(sender); check(false, "own-team failure invalidates cached admission") }
        catch { check(error as? AppleEventAuthorization.Failure == .teamNotFound, "own-team failure invalidates cached admission") }
        ownTeam = ownTeamID; processTeam = ownTeamID
        _ = try adapter.authorizeAppleEventSignedClient(.init(pid: 41, auditData: nil, version: nil), resolveContext: { context($0) })
        processTeam = foreignTeamID
        do { _ = try adapter.authorizeAppleEventSignedClient(.init(pid: 41, auditData: nil, version: nil), resolveContext: { context($0) }) }
        catch {}
        check(processes == 2, "PID signature checks are refreshed rather than cached")

        var token = audit_token_t(); token.val.1 = 501; token.val.5 = 41
        let data = withUnsafeBytes(of: &token) { Data($0) }
        let developer = try adapter.authorizeAppleEvent(.init(pid: 41, auditData: data,
            version: AppleEventAuthorization.nativeBridgeVersion, clientType: "node_repl"), development: true,
            serviceUID: 501, resolveContext: { context($0) })
        check(!developer.foregroundOnly && developer.clientMetadata.clientType == .nodeRepl && developer.clientMetadata.mcpRuntime == nil,
              "explicit unsigned-local mode keeps token admission and captures native client metadata")
        for value in [AppleEventAuthorization.Sender(pid: 42, auditData: data, version: nil), .init(pid: 41, auditData: nil, version: nil)] {
            do { _ = try adapter.authorizeAppleEvent(value, development: true, serviceUID: 501); check(false, "development mode rejects missing or mismatched tokens") }
            catch { check(error as? AppleEventAuthorization.Failure == .notAuthenticated, "development mode rejects missing or mismatched tokens") }
        }
        let report: [String: Any] = ["passed": results.allSatisfy { $0["passed"] as? Bool == true }, "cases": results.count,
            "results": results, "nativeProcessSigningQueries": false, "nativeRequests": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if report["passed"] as? Bool != true { exit(1) }
    }
}
