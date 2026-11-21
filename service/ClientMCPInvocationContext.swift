import Foundation
import MCP

enum CUAMCPInvocationContext {
    @TaskLocal static var startedAt: Date?
    /// Whether this tool call's client declared form elicitation. Set by
    /// `CUAMCPServer` from `CUAMCPClientCapabilities`.
    @TaskLocal static var clientSupportsElicitation = false

    /// A turn metadata key is accepted only as an object; strings
    /// containing JSON and other Value cases do not create a scope.
    static func field(_ metadata: Metadata?, key: String) -> AcuaTurnMetadataField {
        guard let value = metadata?[key] else {
            return .absent
        }

        guard case .object(let object) = value, let data = try? JSONEncoder().encode(object) else {
            return .notAnObject
        }

        return .object(data)
    }

    static func turn(_ metadata: Metadata?, scope: AcuaMCPTurnScope) throws -> ComputerUseJSONRPCCodexTurnMetadata {
        try scope.metadata(acuaTurn: field(metadata, key: AcuaTurnMetadataKey.acua),
                           agentTurn: field(metadata, key: AcuaTurnMetadataKey.codex))
    }

    static func withTurn<T>(_ turn: ComputerUseJSONRPCCodexTurnMetadata, operation: () async throws -> T) async rethrows -> T {
        try await ComputerUseTelemetryContext.withAgentTurnMetadata(try? JSONEncoder().encode(turn), operation: operation)
    }
}
