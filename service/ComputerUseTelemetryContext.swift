import Foundation

// The transport and Logging.AgentTurnMetadata use the same six snake-case keys.
struct ComputerUseJSONRPCCodexTurnMetadata: Codable, Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var sessionID: String?
    var turnID: String?
    var turnStartedAtUnixMilliseconds: Int64?
    var userInputRequestedDuringTurn: Bool?
    enum CodingKeys: String, CodingKey {
        case model
        case reasoningEffort = "reasoning_effort"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case turnStartedAtUnixMilliseconds = "turn_started_at_unix_ms"
        case userInputRequestedDuringTurn = "user_input_requested_during_turn"
    }
}

enum ComputerUseTelemetryContext {
    struct Snapshot: Equatable, Sendable {
        var agentModel: String?
        var agentReasoningEffort: String?
        var agentSessionID: String?
        var agentTurnID: String?
        var agentTurnStartedAtUnixMilliseconds: Int64?
        var agentUserInputRequestedDuringTurn: Bool?
        init(_ metadata: ComputerUseJSONRPCCodexTurnMetadata = .init()) {
            agentModel = metadata.model
            agentReasoningEffort = metadata.reasoningEffort
            agentSessionID = metadata.sessionID
            agentTurnID = metadata.turnID
            agentTurnStartedAtUnixMilliseconds = metadata.turnStartedAtUnixMilliseconds
            agentUserInputRequestedDuringTurn = metadata.userInputRequestedDuringTurn
        }
        var isEmpty: Bool {
            agentModel == nil && agentReasoningEffort == nil && agentSessionID == nil && agentTurnID == nil &&
            agentTurnStartedAtUnixMilliseconds == nil && agentUserInputRequestedDuringTurn == nil
        }
        func agentTurnMetadataData() -> Data? {
            guard !isEmpty else { return nil }
            return try? JSONEncoder().encode(ComputerUseJSONRPCCodexTurnMetadata(
                model: agentModel, reasoningEffort: agentReasoningEffort, sessionID: agentSessionID,
                turnID: agentTurnID, turnStartedAtUnixMilliseconds: agentTurnStartedAtUnixMilliseconds,
                userInputRequestedDuringTurn: agentUserInputRequestedDuringTurn))
        }
    }
    @TaskLocal static var current = Snapshot()
    static func snapshot() -> Snapshot { current }

    // Absent, empty and undecodable metadata is ignored rather
    // than clearing an inherited scope. A present partial value replaces it.
    private static func replacement(_ data: Data?) -> Snapshot? {
        guard let data, let metadata = try? JSONDecoder().decode(ComputerUseJSONRPCCodexTurnMetadata.self, from: data) else { return nil }
        let snapshot = Snapshot(metadata)
        return snapshot.isEmpty ? nil : snapshot
    }
    static func withAgentTurnMetadata<T>(_ data: Data?, operation: () throws -> T) rethrows -> T {
        guard let replacement = replacement(data) else { return try operation() }
        return try $current.withValue(replacement, operation: operation)
    }
    static func withAgentTurnMetadata<T>(_ data: Data?, operation: () async throws -> T) async rethrows -> T {
        guard let replacement = replacement(data) else { return try await operation() }
        return try await $current.withValue(replacement) { try await operation() }
    }

    // The outer JSON-RPC decoder is strict about known field types. This is
    // separate from the tolerant Logging scope above. Unknown keys are ignored.
    static func validatedWireData(_ value: Any?) throws -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let metadata = try JSONDecoder().decode(ComputerUseJSONRPCCodexTurnMetadata.self, from: data)
        return try JSONEncoder().encode(metadata)
    }
}
