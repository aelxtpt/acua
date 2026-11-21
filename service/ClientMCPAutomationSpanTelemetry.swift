import MCP

struct AutomationMCPSpanTelemetry: Sendable {
    /// The result `_meta` key Codex hosts read tool span telemetry from.
    static let metadataKey = "codex/telemetry"

    let targetID: String?
    let didTriggerServerUserFlow: Bool

    var value: Value {
        var span: [String: Value] = ["did_trigger_server_user_flow": .bool(didTriggerServerUserFlow)]
        if let targetID, !targetID.isEmpty { span["target_id"] = .string(targetID) }
        return .object(["span": .object(span)])
    }

    static func attaching(_ span: Self?, to result: CallTool.Result) -> CallTool.Result {
        guard let span else { return result }
        var metadata = result._meta ?? .init()
        metadata.fields[Self.metadataKey] = span.value
        metadata.progressToken = nil
        return .init(content: result.content, structuredContent: result.structuredContent,
            isError: result.isError, toolResult: result.toolResult, _meta: metadata)
    }
}
