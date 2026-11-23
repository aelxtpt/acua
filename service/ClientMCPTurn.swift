import Foundation

/// `_meta` keys that name the agent turn an MCP tool call belongs to.
enum AcuaTurnMetadataKey {
    /// The public ACUA key: `{"session_id": "...", "turn_id": "..."}`.
    static let acua = "x-acua-turn"
    /// The Codex key, still accepted so Codex hosts keep working unchanged.
    static let codex = "x-codex-turn-metadata"
}

/// One `_meta` entry as the MCP layer found it, before decoding.
enum AcuaTurnMetadataField: Equatable {
    case absent
    case notAnObject
    case object(Data)
}

enum AcuaTurnMetadataError: Error, Equatable, CustomStringConvertible {
    case acuaTurnIsNotAnObject
    case acuaTurnHasInvalidFields(String)
    case endTurnArgumentIsNotAString(String)
    case endTurnArgumentIsEmpty(String)

    var description: String {
        switch self {
        case .acuaTurnIsNotAnObject:
            "Invalid _meta.\(AcuaTurnMetadataKey.acua): expected an object such as {\"session_id\": \"...\", \"turn_id\": \"...\"}"
        case .acuaTurnHasInvalidFields(let detail):
            "Invalid _meta.\(AcuaTurnMetadataKey.acua): \(detail)"
        case .endTurnArgumentIsNotAString(let name):
            "Invalid end_turn argument \(name): expected a string"
        case .endTurnArgumentIsEmpty(let name):
            "Invalid end_turn argument \(name): expected a non-empty string"
        }
    }
}

struct AcuaEndTurnArguments: Equatable {
    var sessionID: String?
    var turnID: String?
}

/// Resolves which session and turn a tool call belongs to, for one MCP
/// connection. The service ties every app an agent touches to that session,
/// and only an end of that turn lifts a "stopped by the user" lock.
struct AcuaMCPTurnScope: Sendable {
    /// Used when a call names no session: the session of the agent process
    /// that started this helper, which that agent's stop hook can end too
    /// (see AcuaAgentProcessSession). A helper with no agent parent, such as
    /// one adopted by launchd, gets a session of its own.
    let implicitSessionID: String

    init(implicitSessionID: String = Self.defaultImplicitSessionID()) {
        self.implicitSessionID = implicitSessionID
    }

    static func defaultImplicitSessionID() -> String {
        AcuaAgentProcessSession.helperSessionID(helperPID: getpid(), lookup: AcuaProcessTable.identity)
            ?? "acua-mcp-" + UUID().uuidString
    }

    /// The ACUA key wins when both are present. The Codex key is lenient: a
    /// value that is not a decodable object is ignored.
    /// The ACUA key is new, so a malformed value is an error rather than being
    /// silently treated as "no turn".
    func metadata(acuaTurn: AcuaTurnMetadataField, agentTurn: AcuaTurnMetadataField) throws -> ComputerUseJSONRPCCodexTurnMetadata {
        let named = try Self.decodeAcuaTurn(acuaTurn) ?? Self.decodeAgentTurn(agentTurn) ?? .init()
        return withSession(named)
    }

    /// No arguments ends the turn this call itself belongs to. A session alone
    /// ends that whole session, whatever turn last used it.
    func endedTurn(arguments: AcuaEndTurnArguments, callMetadata: ComputerUseJSONRPCCodexTurnMetadata) -> AgentTurnEndedRequest {
        let call = withSession(callMetadata)

        if let sessionID = arguments.sessionID {
            return .init(threadID: sessionID, turnID: arguments.turnID)
        }

        return .init(threadID: call.sessionID ?? implicitSessionID, turnID: arguments.turnID ?? call.turnID)
    }

    private func withSession(_ metadata: ComputerUseJSONRPCCodexTurnMetadata) -> ComputerUseJSONRPCCodexTurnMetadata {
        var resolved = metadata
        let session = resolved.sessionID ?? ""

        if session.isEmpty {
            resolved.sessionID = implicitSessionID
        }

        return resolved
    }

    private static func decodeAcuaTurn(_ field: AcuaTurnMetadataField) throws -> ComputerUseJSONRPCCodexTurnMetadata? {
        switch field {
        case .absent:
            return nil
        case .notAnObject:
            throw AcuaTurnMetadataError.acuaTurnIsNotAnObject
        case .object(let data):
            do {
                return try JSONDecoder().decode(ComputerUseJSONRPCCodexTurnMetadata.self, from: data)
            } catch {
                throw AcuaTurnMetadataError.acuaTurnHasInvalidFields(String(describing: error))
            }
        }
    }

    private static func decodeAgentTurn(_ field: AcuaTurnMetadataField) -> ComputerUseJSONRPCCodexTurnMetadata? {
        guard case .object(let data) = field else {
            return nil
        }

        return try? JSONDecoder().decode(ComputerUseJSONRPCCodexTurnMetadata.self, from: data)
    }
}
