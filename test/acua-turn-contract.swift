import Foundation

// Unit tests for the public turn contract: which turn an agent's call belongs
// to, and when ending a turn releases a "stopped by the user" lock.
// No service or MCP connection is started.

@main
enum AcuaTurnContractTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool) {
        guard condition else {
            print("FAIL \(name)")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    static func main() throws {
        sessionTrackerTests()
        try turnScopeTests()
        endTurnTests()
        print("\(passed) turn contract tests passed")
    }

    // MARK: - Service session tracker

    private static func sessionTrackerTests() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        let matching = ComputerUseSessionTracker()
        matching.recordUse("com.apple.TextEdit", threadID: "session", turnID: "turn-1")
        check("SessionTrackerEnd_MatchingTurn_ReleasesApps",
              matching.end(threadID: "session", turnID: "turn-1", now: now) == ["com.apple.TextEdit"])

        let different = ComputerUseSessionTracker()
        different.recordUse("com.apple.TextEdit", threadID: "session", turnID: "turn-1")
        check("SessionTrackerEnd_DifferentTurn_KeepsApps",
              different.end(threadID: "session", turnID: "turn-other", now: now).isEmpty)
        check("SessionTrackerEnd_DifferentTurnThenMatchingTurn_ReleasesApps",
              different.end(threadID: "session", turnID: "turn-1", now: now) == ["com.apple.TextEdit"])

        let wholeSession = ComputerUseSessionTracker()
        wholeSession.recordUse("com.apple.TextEdit", threadID: "session", turnID: "turn-1")
        check("SessionTrackerEnd_NoTurnID_ReleasesWholeSession",
              wholeSession.end(threadID: "session", turnID: nil, now: now) == ["com.apple.TextEdit"])

        // An implicit per-connection session carries no turn identifier.
        let implicit = ComputerUseSessionTracker()
        implicit.recordUse("com.apple.TextEdit", threadID: "connection", turnID: nil)
        check("SessionTrackerEnd_UseWithoutTurnID_ReleasesOnSessionEnd",
              implicit.end(threadID: "connection", turnID: nil, now: now) == ["com.apple.TextEdit"])

        let newerTurn = ComputerUseSessionTracker()
        newerTurn.recordUse("com.apple.TextEdit", threadID: "session", turnID: "turn-1")
        newerTurn.recordUse("com.apple.Safari", threadID: "session", turnID: "turn-2")
        check("SessionTrackerEnd_LateEndOfOlderTurn_KeepsNewerTurnApps",
              newerTurn.end(threadID: "session", turnID: "turn-1", now: now).isEmpty)
        check("SessionTrackerEnd_EndOfNewerTurn_ReleasesAllSessionApps",
              newerTurn.end(threadID: "session", turnID: "turn-2", now: now) == ["com.apple.TextEdit", "com.apple.Safari"])

        let shared = ComputerUseSessionTracker()
        shared.recordUse("com.apple.TextEdit", threadID: "first", turnID: "turn-1")
        shared.recordUse("com.apple.TextEdit", threadID: "second", turnID: "turn-9")
        check("SessionTrackerEnd_AppUsedByAnotherSession_StaysLocked",
              shared.end(threadID: "first", turnID: "turn-1", now: now).isEmpty)

        let ignored = ComputerUseSessionTracker()
        ignored.recordUse("com.apple.TextEdit", threadID: "session", turnID: "turn-1")
        _ = ignored.end(threadID: "session", turnID: "turn-other", now: now)
        check("SessionTrackerEnd_DifferentTurn_StillMarksThatTurnEnded",
              ignored.hasEnded("turn-other", now: now) && !ignored.hasEnded("turn-1", now: now))
    }

    // MARK: - MCP client turn scope

    private static func object(_ json: String) -> AcuaTurnMetadataField {
        .object(Data(json.utf8))
    }

    private static func metadataError(_ scope: AcuaMCPTurnScope, acua: AcuaTurnMetadataField) -> AcuaTurnMetadataError? {
        do {
            _ = try scope.metadata(acuaTurn: acua, agentTurn: .absent)
            return nil
        } catch let error as AcuaTurnMetadataError {
            return error
        } catch {
            return nil
        }
    }

    private static func turnScopeTests() throws {
        let scope = AcuaMCPTurnScope(implicitSessionID: "connection")

        let acua = try scope.metadata(acuaTurn: object(#"{"session_id":"agent","turn_id":"t1"}"#), agentTurn: .absent)
        check("TurnScopeMetadata_AcuaKey_UsesItsSessionAndTurn",
              acua.sessionID == "agent" && acua.turnID == "t1")

        let codex = try scope.metadata(acuaTurn: .absent, agentTurn: object(#"{"session_id":"thread","turn_id":"t2","model":"m"}"#))
        check("TurnScopeMetadata_CodexKey_IsStillAccepted",
              codex.sessionID == "thread" && codex.turnID == "t2" && codex.model == "m")

        let both = try scope.metadata(acuaTurn: object(#"{"session_id":"agent","turn_id":"t1"}"#),
                                      agentTurn: object(#"{"session_id":"thread","turn_id":"t2"}"#))
        check("TurnScopeMetadata_BothKeys_AcuaKeyWins",
              both.sessionID == "agent" && both.turnID == "t1")

        let none = try scope.metadata(acuaTurn: .absent, agentTurn: .absent)
        check("TurnScopeMetadata_NoMeta_UsesConnectionSessionWithoutTurn",
              none.sessionID == "connection" && none.turnID == nil)

        let turnOnly = try scope.metadata(acuaTurn: object(#"{"turn_id":"t1"}"#), agentTurn: .absent)
        check("TurnScopeMetadata_TurnWithoutSession_UsesConnectionSession",
              turnOnly.sessionID == "connection" && turnOnly.turnID == "t1")

        let emptySession = try scope.metadata(acuaTurn: object(#"{"session_id":"","turn_id":"t1"}"#), agentTurn: .absent)
        check("TurnScopeMetadata_EmptySession_UsesConnectionSession",
              emptySession.sessionID == "connection" && emptySession.turnID == "t1")

        let codexString = try scope.metadata(acuaTurn: .absent, agentTurn: .notAnObject)
        check("TurnScopeMetadata_CodexKeyNotAnObject_IsIgnored",
              codexString.sessionID == "connection" && codexString.turnID == nil)

        let codexWrongType = try scope.metadata(acuaTurn: .absent, agentTurn: object(#"{"turn_id":7}"#))
        check("TurnScopeMetadata_CodexKeyWrongFieldType_IsIgnored",
              codexWrongType.sessionID == "connection" && codexWrongType.turnID == nil)

        check("TurnScopeMetadata_AcuaKeyNotAnObject_IsRejected",
              metadataError(scope, acua: .notAnObject) == .acuaTurnIsNotAnObject)

        if case .acuaTurnHasInvalidFields? = metadataError(scope, acua: object(#"{"turn_id":7}"#)) {
            check("TurnScopeMetadata_AcuaKeyWrongFieldType_IsRejected", true)
        } else {
            check("TurnScopeMetadata_AcuaKeyWrongFieldType_IsRejected", false)
        }

        check("TurnScope_DefaultImplicitSessions_AreDistinctPerConnection",
              AcuaMCPTurnScope().implicitSessionID != AcuaMCPTurnScope().implicitSessionID)
    }

    // MARK: - end_turn

    private static func endTurnTests() {
        let scope = AcuaMCPTurnScope(implicitSessionID: "connection")
        let call = ComputerUseJSONRPCCodexTurnMetadata(sessionID: "agent", turnID: "t1")

        check("EndTurn_NoArguments_EndsTheCallsOwnTurn",
              scope.endedTurn(arguments: .init(), callMetadata: call) == .init(threadID: "agent", turnID: "t1"))

        check("EndTurn_NoArgumentsNoMeta_EndsTheConnectionSession",
              scope.endedTurn(arguments: .init(), callMetadata: .init()) == .init(threadID: "connection", turnID: nil))

        check("EndTurn_SessionArgumentOnly_EndsThatWholeSession",
              scope.endedTurn(arguments: .init(sessionID: "other"), callMetadata: call) == .init(threadID: "other", turnID: nil))

        check("EndTurn_SessionAndTurnArguments_EndThatTurn",
              scope.endedTurn(arguments: .init(sessionID: "other", turnID: "t9"), callMetadata: call) == .init(threadID: "other", turnID: "t9"))

        check("EndTurn_TurnArgumentOnly_UsesTheCallsSession",
              scope.endedTurn(arguments: .init(turnID: "t9"), callMetadata: call) == .init(threadID: "agent", turnID: "t9"))
    }
}
