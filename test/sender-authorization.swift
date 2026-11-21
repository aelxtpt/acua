import Foundation
import Darwin

@main enum SenderAuthorizationTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ name: String, _ valid: Bool) { precondition(valid, name); count += 1; print("PASS \(name)") }
        func credentials(_ byte: UInt8 = 1, pid: Int32 = 123, uid: uid_t = 501) -> PeerAuditCredentials {
            PeerAuditCredentials(pid: pid, uid: uid, auditToken: Data(repeating: byte, count: 32))
        }
        let ownTeamID = "TESTTEAM01", foreignTeamID = "OTHERTEAM1"
        var lookupCount = 0, own: String? = ownTeamID, observed: String? = ownTeamID
        let trustedParent = SenderProcessIdentity(team: ownTeamID)
        var context = [trustedParent]
        let auth = SenderAuthorization(ownTeam: { own }, peerTeam: { _ in lookupCount += 1; return observed },
                                       ancestors: { _ in context })
        check("peer signed by the service's own team is accepted", auth.allowsSignedClient(credentials()))
        check("positive audit-token result is cached", auth.cachedCount == 1 && lookupCount == 1)
        observed = nil
        check("same audit identity reuses its verified team", auth.allowsSignedClient(credentials()) && lookupCount == 1)
        check("different full audit token cannot reuse the cached result", !auth.allowsSignedClient(credentials(2)) && lookupCount == 2)
        observed = foreignTeamID
        check("peer signed by another team is rejected", !auth.allowsSignedClient(credentials(4)))
        let negatives = lookupCount
        check("negative result is not cached", !auth.allowsSignedClient(credentials(4)) && lookupCount == negatives + 1 && auth.cachedCount == 1)
        observed = ownTeamID.lowercased()
        check("team identifiers remain case sensitive", !auth.allowsSignedClient(credentials(5)))
        observed = ownTeamID
        check("a second own-team peer is accepted and cached", auth.allowsSignedClient(credentials(3)) && auth.cachedCount == 2)
        own = nil
        let beforeMissingOwn = lookupCount
        check("missing own team rejects even a cached own-team match", !auth.allowsSignedClient(credentials()) && lookupCount == beforeMissingOwn)
        check("missing own team rejects before the first lookup", !auth.allowsSignedClient(credentials(6)) && lookupCount == beforeMissingOwn)
        own = "NEWTEAM001"
        observed = nil
        check("old same-team cache is revalidated against the current own team", !auth.allowsSignedClient(credentials(3)))
        observed = "NEWTEAM001"; context = [SenderProcessIdentity(team: "NEWTEAM001")]
        check("new own-team criterion can replace a prior cached team", auth.allowsSignedClient(credentials(3)))
        let incomplete = PeerAuditCredentials(pid: 123, uid: 501, auditToken: Data(repeating: 0, count: 31))
        check("invalid audit-token length cannot authorize", !auth.allowsSignedClient(incomplete) && !auth.allows(incomplete, serviceUID: 501))
        check("missing kernel PID cannot authorize", !auth.allowsSignedClient(credentials(pid: 0)) && !auth.allows(credentials(pid: -1), serviceUID: 501))
        own = nil
        let beforeDevelopment = lookupCount
        check("explicit development mode accepts same local user", auth.allows(credentials(uid: 501), serviceUID: 501))
        check("development mode still rejects another local user", !auth.allows(credentials(uid: 502), serviceUID: 501))
        let productLookups = lookupCount
        observed = "UNSIGNEDORANYTEAM"; context = [SenderProcessIdentity(team: "ANTHROPICORANY")]
        check("Aex admission accepts any same-user process regardless of team or parent",
              auth.allows(credentials(9, uid: 501), serviceUID: 501) && auth.allows(credentials(10, uid: 501), development: false, serviceUID: 501))
        check("Aex admission rejects another local user", !auth.allows(credentials(11, uid: 502), serviceUID: 501))
        check("Aex admission performs no signature lookup", lookupCount == productLookups)
        observed = "NEWTEAM001"; context = [SenderProcessIdentity(team: "NEWTEAM001")]
        check("development mode does not poison signing cache", auth.cachedCount == 2 && lookupCount == beforeDevelopment)
        check("development mode cannot grant later strict admission", !auth.allowsSignedClient(credentials(7)))
        check("invalid descriptor cannot produce kernel credentials", PeerAuditCredentials.read(fd: -1) == nil)
        check("truncated untrusted token is not passed to Security", SigningTeam.peer(auditToken: Data()) == nil)
        check("responsibility lookup ignores invalid or missing senders",
              SenderProcessResponsibility.responsiblePID(for: 0) == nil &&
              SenderProcessResponsibility.responsiblePID(for: -1) == nil &&
              SenderProcessResponsibility.responsiblePID(for: Int32.max) == nil)
        own = "NEWTEAM001"
        context = []
        check("cached signed peer is rejected when its parent context disappears",
              !auth.allowsSignedClient(credentials(3)))
        context = [SenderProcessIdentity(team: "NEWTEAM001")]
        check("parent context is recomputed separately from the signing cache",
              auth.allowsSignedClient(credentials(3)))
        let foreignParent = SenderProcessIdentity(team: foreignTeamID, executable: "node")
        let ownSigningIDElsewhere = SenderProcessIdentity(team: foreignTeamID, signingID: AcuaOwnIdentity.bundleIdentifier)
        check("own-team parent requires no ancestor", SenderContextAuthorization.allows([trustedParent], ownTeam: ownTeamID))
        check("missing parent is not trusted", !SenderContextAuthorization.allows([], ownTeam: ownTeamID))
        check("parent of another team is not trusted", !SenderContextAuthorization.allows([foreignParent], ownTeam: ownTeamID))
        check("own bundle or signing identifier does not replace the own team",
              !SenderContextAuthorization.allows([ownSigningIDElsewhere], ownTeam: ownTeamID))
        check("an untrusted immediate parent cannot borrow a trusted ancestor",
              !SenderContextAuthorization.allows([foreignParent, trustedParent], ownTeam: ownTeamID))
        check("ancestor walk is bounded to eight parents",
              SenderProcessResponsibility.ancestors(of: 1) { $0 + 1 } == Array(2...9))
        check("ancestor walk stops before revisiting the sender or another parent",
              SenderProcessResponsibility.ancestors(of: 1) { $0 == 3 ? 1 : $0 + 1 } == [2, 3] &&
              SenderProcessResponsibility.ancestors(of: 1) { $0 == 4 ? 2 : $0 + 1 } == [2, 3, 4])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        typealias Responsibility = @convention(c) (pid_t) -> pid_t
        let expected = dlopen(nil, RTLD_LAZY).flatMap { dlsym($0, "responsibility_get_pid_responsible_for_pid") }
            .map { unsafeBitCast($0, to: Responsibility.self)(getpid()) }
        check("a real child is resolved from the responsibility of its known parent",
              SenderProcessResponsibility.responsiblePID(for: child.processIdentifier) == expected.flatMap { $0 > 0 ? $0 : nil })
        check("real native child resolves the calling process as its first ancestor",
              SenderProcessResponsibility.ancestors(of: child.processIdentifier).first == getpid())
        check("native process identity reads the kernel executable basename",
              SenderProcessIdentity.resolve(child.processIdentifier).executable == "sleep")
        let childContext = SenderRequestContext.resolveNative(child.processIdentifier)
        check("native socket context records node runtime without claiming a node client",
              childContext?.clientMetadata == .socket)
        check("native sender context snapshots the verified child's parent and ancestry",
              childContext?.senderPID == child.processIdentifier &&
              childContext?.parentIdentity == SenderProcessIdentity.resolve(getpid()) &&
              childContext?.ancestorIdentities.first == childContext?.parentIdentity)
        check("native sender context uses the parent's responsible process identity",
              childContext?.responsibleIdentity == expected.flatMap { $0 > 0 ? SenderProcessIdentity.resolve($0) : nil })
        check("invalid native peers do not create a sender context",
              SenderRequestContext.resolveNative(0) == nil && SenderRequestContext.resolveNative(-1) == nil)
        check("managed service mode uses ACUA's own host bundle identity",
              ServiceClientLifetime.Mode.detect(parent: 42) { _ in .init(bundleID: "com.aex.computeruse.client") } == .managed(42) &&
              ServiceClientLifetime.Mode.detect(parent: 43) { _ in .init(bundleID: "com.aex.computeruse") } == .managed(43))
        check("a signing ID alone never makes a parent ACUA's own host",
              ServiceClientLifetime.Mode.detect(parent: 42) { _ in .init(signingID: "com.aex.computeruse.client") } == .standalone)
        check("missing owner, other apps, executable aliases and case differences leave standalone mode",
              ServiceClientLifetime.Mode.detect(parent: nil) { _ in fatalError("unexpected lookup") } == .standalone &&
              ServiceClientLifetime.Mode.detect(parent: 42) { _ in .init(bundleID: "com.example.agent") } == .standalone &&
              ServiceClientLifetime.Mode.detect(parent: 42) { _ in .init(executable: "com.aex.computeruse.client") } == .standalone &&
              ServiceClientLifetime.Mode.detect(parent: 42) { _ in .init(bundleID: "com.aex.ComputerUse.client") } == .standalone)
        func spawn() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["10"]
            try process.run()
            return process
        }
        func finish(_ process: Process) {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        func runLoop(_ timeout: TimeInterval, until condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !condition() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
        }
        let firstPeer = try spawn()
        let lastPeer = try spawn()
        defer { finish(firstPeer); finish(lastPeer) }
        var standaloneExits = 0
        let standalone = ServiceClientLifetime(mode: .standalone) { standaloneExits += 1 }
        standalone.start()
        standalone.admit(firstPeer.processIdentifier)
        standalone.admit(firstPeer.processIdentifier)
        standalone.admit(lastPeer.processIdentifier)
        finish(firstPeer)
        runLoop(0.2, until: { standaloneExits > 0 })
        check("standalone service stays while an authenticated peer remains", standaloneExits == 0)
        finish(lastPeer)
        runLoop(2, until: { standaloneExits > 0 })
        check("last native peer exit requests shutdown exactly once", standaloneExits == 1)
        standalone.stop()

        let owner = try spawn()
        let otherPeer = try spawn()
        defer { finish(owner); finish(otherPeer) }
        var managedExits = 0
        let managed = ServiceClientLifetime(mode: .managed(owner.processIdentifier)) { managedExits += 1 }
        managed.start()
        managed.admit(otherPeer.processIdentifier)
        finish(otherPeer)
        runLoop(0.2, until: { managedExits > 0 })
        check("managed service ignores an authenticated client exit", managedExits == 0)
        finish(owner)
        runLoop(2, until: { managedExits > 0 })
        check("native managed owner exit requests shutdown", managedExits == 1)
        managed.stop()

        let cancelledPeer = try spawn()
        defer { finish(cancelledPeer) }
        var cancelledExits = 0
        let cancelled = ServiceClientLifetime(mode: .standalone) { cancelledExits += 1 }
        cancelled.admit(cancelledPeer.processIdentifier)
        cancelled.stop()
        finish(cancelledPeer)
        runLoop(0.2, until: { cancelledExits > 0 })
        check("stopping cancels outstanding native exit monitors", cancelledExits == 0)
        var idleExits = 0
        var keepAliveChecks = 0
        let idle = ServiceIdleTimer(idlePeriod: .milliseconds(90), keepAlive: {
            keepAliveChecks += 1
            return keepAliveChecks == 1
        }, onIdle: { idleExits += 1 })
        idle.reset()
        runLoop(2, until: { keepAliveChecks > 0 })
        check("an active native owner rearms the idle timer", keepAliveChecks == 1 && idleExits == 0)
        runLoop(2, until: { idleExits > 0 })
        check("the next idle period terminates once the owner is inactive", keepAliveChecks == 2 && idleExits == 1)
        idle.reset()
        runLoop(0.15, until: { idleExits > 1 })
        check("an expired idle timer cannot arm again", idleExits == 1)

        var resetExits = 0
        let resetIdle = ServiceIdleTimer(idlePeriod: .milliseconds(120), keepAlive: { false }, onIdle: { resetExits += 1 })
        resetIdle.reset()
        runLoop(0.06, until: { false })
        resetIdle.reset()
        runLoop(0.075, until: { resetExits > 0 })
        check("a new request cancels the old idle deadline", resetExits == 0)
        runLoop(2, until: { resetExits > 0 })
        check("the renewed idle deadline still expires", resetExits == 1)

        var stoppedIdleExits = 0
        let stoppedIdle = ServiceIdleTimer(idlePeriod: .milliseconds(60), keepAlive: { false }, onIdle: { stoppedIdleExits += 1 })
        stoppedIdle.reset()
        stoppedIdle.stop()
        stoppedIdle.reset()
        runLoop(0.15, until: { stoppedIdleExits > 0 })
        check("shutdown cancels idle work and rejects late refreshes", stoppedIdleExits == 0)
        print("ALL \(count) SENDER AUTHORIZATION POLICY CHECKS PASSED; signed-team positive admission requires native signed fixtures")
    }
}
