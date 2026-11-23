import Darwin
import Foundation

// Unit tests for the agent-process session: how an agent's stop hook and the
// MCP helper the agent started agree on one session without the agent naming
// it. Process tables are stubbed, except for the checks of the real kernel
// lookup, which only read this test's own process.

@main
enum AcuaAgentProcessTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static func process(_ pid: pid_t, parent: pid_t, start: Int = 1_700_000_000, micro: Int = 42) -> AcuaProcessIdentity {
        AcuaProcessIdentity(pid: pid, parentPID: parent, startSeconds: start, startMicroseconds: micro)
    }

    /// A process tree like the one Claude Code builds: the agent (200) starts
    /// the MCP helper (300) directly and runs a hook through /bin/sh (400),
    /// which starts the CLI (500). The agent's own parent is a shell (100).
    private static let agentTree: [pid_t: AcuaProcessIdentity] = [
        100: process(100, parent: 1, start: 1_600_000_000, micro: 7),
        200: process(200, parent: 100, start: 1_700_000_000, micro: 42),
        300: process(300, parent: 200),
        400: process(400, parent: 200),
        500: process(500, parent: 400),
    ]

    private static func lookup(_ table: [pid_t: AcuaProcessIdentity]) -> (pid_t) -> AcuaProcessIdentity? {
        { table[$0] }
    }

    static func main() async {
        sessionIdentifierTests()
        helperSessionTests()
        hookSessionTests()
        kernelLookupTests()
        await agentTurnEndedTests()
        print("\(passed) agent process tests passed")
    }

    // MARK: - Session identifier

    private static func sessionIdentifierTests() {
        let agent = process(200, parent: 100, start: 1_700_000_000, micro: 42)

        check("SessionID_AgentProcess_NamesPIDAndStartTime",
              AcuaAgentProcessSession.sessionID(agent) == "acua-agent-200-1700000000.000042",
              AcuaAgentProcessSession.sessionID(agent))

        check("SessionID_SamePIDLaterStart_IsADifferentSession",
              AcuaAgentProcessSession.sessionID(agent)
                  != AcuaAgentProcessSession.sessionID(process(200, parent: 100, start: 1_700_000_001, micro: 42)))
    }

    // MARK: - MCP helper side

    private static func helperSessionTests() {
        check("HelperSession_StartedByAgent_IsTheAgentsSession",
              AcuaAgentProcessSession.helperSessionID(helperPID: 300, lookup: lookup(agentTree))
                  == "acua-agent-200-1700000000.000042")

        let orphan: [pid_t: AcuaProcessIdentity] = [300: process(300, parent: 1), 1: process(1, parent: 0)]
        check("HelperSession_ParentIsLaunchd_HasNoAgentSession",
              AcuaAgentProcessSession.helperSessionID(helperPID: 300, lookup: lookup(orphan)) == nil)

        let parentGone: [pid_t: AcuaProcessIdentity] = [300: process(300, parent: 200)]
        check("HelperSession_ParentAlreadyExited_HasNoAgentSession",
              AcuaAgentProcessSession.helperSessionID(helperPID: 300, lookup: lookup(parentGone)) == nil)

        check("HelperSession_UnknownHelper_HasNoAgentSession",
              AcuaAgentProcessSession.helperSessionID(helperPID: 999, lookup: lookup(agentTree)) == nil)

        // Every connection the same agent process opens is one session, so a
        // hook of that agent ends them together.
        let twoHelpers = agentTree.merging([301: process(301, parent: 200)]) { current, _ in current }
        check("HelperSession_TwoHelpersOfOneAgent_ShareTheSession",
              AcuaAgentProcessSession.helperSessionID(helperPID: 300, lookup: lookup(twoHelpers))
                  == AcuaAgentProcessSession.helperSessionID(helperPID: 301, lookup: lookup(twoHelpers)))
    }

    // MARK: - Hook side

    private static func hookSessionTests() {
        let throughShell = AcuaAgentProcessSession.hookSessionIDs(hookPID: 500, lookup: lookup(agentTree))
        check("HookSessions_RunThroughShell_IncludeTheAgentsSession",
              throughShell.contains("acua-agent-200-1700000000.000042"), "\(throughShell)")

        check("HookSessions_RunThroughShell_StopAtTheGrandparent",
              throughShell == [AcuaAgentProcessSession.sessionID(agentTree[400]!),
                               AcuaAgentProcessSession.sessionID(agentTree[200]!)], "\(throughShell)")

        // `sh -c` may exec a single command, so the CLI is the agent's child.
        let direct = AcuaAgentProcessSession.hookSessionIDs(hookPID: 400, lookup: lookup(agentTree))
        check("HookSessions_ExecutedDirectly_IncludeTheAgentsSession",
              direct.first == "acua-agent-200-1700000000.000042", "\(direct)")

        check("HookSessions_HookAndHelperOfOneAgent_Match",
              throughShell.contains(AcuaAgentProcessSession.helperSessionID(helperPID: 300, lookup: lookup(agentTree))!))

        // A second agent in another terminal tab shares only distant
        // ancestors with the first, which the two-level walk never reaches.
        var twoAgents = agentTree
        twoAgents[110] = process(110, parent: 1)
        twoAgents[210] = process(210, parent: 110, start: 1_700_000_500)
        twoAgents[310] = process(310, parent: 210)
        let otherHelper = AcuaAgentProcessSession.helperSessionID(helperPID: 310, lookup: lookup(twoAgents))!
        check("HookSessions_OtherAgentsHelper_IsNeverEnded",
              !AcuaAgentProcessSession.hookSessionIDs(hookPID: 500, lookup: lookup(twoAgents)).contains(otherHelper))

        let underLaunchd: [pid_t: AcuaProcessIdentity] = [500: process(500, parent: 1)]
        check("HookSessions_ParentIsLaunchd_AreEmpty",
              AcuaAgentProcessSession.hookSessionIDs(hookPID: 500, lookup: lookup(underLaunchd)).isEmpty)
    }

    // MARK: - Kernel lookup

    private static func kernelLookupTests() {
        let me = AcuaProcessTable.identity(of: getpid())
        check("ProcessTable_OwnProcess_ReportsItsParent", me?.parentPID == getppid(), "\(String(describing: me))")

        check("ProcessTable_OwnProcess_StartedInThePast",
              (me?.startSeconds ?? 0) > 0 && (me?.startSeconds ?? .max) <= Int(Date().timeIntervalSince1970))

        check("ProcessTable_SameProcessTwice_IsTheSameIdentity",
              AcuaProcessTable.identity(of: getpid()) == me)

        // PIDs never reach Int32.max on macOS (kern.maxproc is far smaller).
        check("ProcessTable_MissingProcess_IsNil", AcuaProcessTable.identity(of: Int32.max) == nil)
    }

    // MARK: - turn-ended --agent-process

    private final class Sent: @unchecked Sendable {
        var requests: [AgentTurnEndedRequest] = []
    }

    @MainActor private static func agentTurnEndedTests() async {
        let sessions = ["acua-agent-400-1.000001", "acua-agent-200-1.000002"]

        let sent = Sent()
        let delivered = await AcuaAgentTurnEnded.run(sessionIDs: sessions,
            findRunningService: { 77 }, send: { service, request in
                guard service == 77 else { return }
                sent.requests.append(request)
            })
        check("AgentTurnEnded_ServiceRunning_EndsEveryCandidateSession",
              sent.requests.map(\.threadID) == sessions && sent.requests.allSatisfy { $0.turnID == nil })
        check("AgentTurnEnded_ServiceRunning_ReportsTheSessions",
              delivered.contains(sessions[0]) && delivered.contains(sessions[1]), delivered)

        let notRunning = Sent()
        let skipped = await AcuaAgentTurnEnded.run(sessionIDs: sessions,
            findRunningService: { Optional<Int>.none }, send: { _, request in notRunning.requests.append(request) })
        check("AgentTurnEnded_ServiceNotRunning_SendsNothing", notRunning.requests.isEmpty)
        check("AgentTurnEnded_ServiceNotRunning_SaysSoAndNamesTheSessions",
              skipped.contains("not running") && skipped.contains(sessions[1]), skipped)

        let none = await AcuaAgentTurnEnded.run(sessionIDs: [],
            findRunningService: { 77 }, send: { _, _ in })
        check("AgentTurnEnded_NoAgentProcess_SaysThereIsNothingToEnd", none.contains("no agent process"), none)

        struct Refused: Error {}
        let partial = Sent()
        let failed = await AcuaAgentTurnEnded.run(sessionIDs: sessions,
            findRunningService: { 77 }, send: { _, request in
                guard request.threadID != sessions[0] else { throw Refused() }
                partial.requests.append(request)
            })
        check("AgentTurnEnded_OneSendFails_StillEndsTheOthers", partial.requests.map(\.threadID) == [sessions[1]])
        check("AgentTurnEnded_OneSendFails_ReportsTheFailure", failed.contains("could not end \(sessions[0])"), failed)
    }
}
