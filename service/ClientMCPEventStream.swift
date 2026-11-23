import Foundation
import MCP

enum CUAEventStreamTelemetry: Equatable, Sendable {
    case toolCalled(name: String, model: String?, reasoningEffort: String?)
    case approvalRequested
    case approvalResolved(action: String)
}

enum EventStreamMCPToolError: Error, CustomStringConvertible {
    case unknownTool(String)
    case recordingStartDeclined
    case recordingStartCanceled

    var description: String {
        switch self {
        case .unknownTool(let name): "Unknown tool: " + name
        case .recordingStartDeclined: "Record & Replay approval denied via MCP elicitation."
        case .recordingStartCanceled: "Record & Replay approval cancelled via MCP elicitation."
        }
    }
}

/// Required typed backend and telemetry sinks keep the MCP layer independent
/// of service discovery while keeping the order of native requests.
struct CUAMCPEventStream: Sendable {
    let status: @Sendable () async throws -> ComputerUseIPCEventStreamSessionStatus
    let start: @Sendable () async throws -> ComputerUseIPCEventStreamSessionStatus
    let stop: @Sendable (ComputerUseIPCEventStreamEndReason) async throws -> ComputerUseIPCEventStreamSessionStatus
    let telemetry: @Sendable (CUAEventStreamTelemetry) -> Void
    /// Asks the user of a client without elicitation (ACUA only).
    let serviceDialog: AcuaMCPElicitation.Ask

    static let approvalMessage = "Allow the agent to record your actions on your Mac?"
    static let approvalSubtitle = "The agent will start recording your mouse clicks, text you type, and the content in windows you interact with until you press Stop (up to 30 minutes). You can cancel any time."
    static var approvalMetadata: Metadata {
        .init(additionalFields: [
            "agent_approval_kind": .string("mcp_tool_call"),
            "connector_id": .string("record-and-replay"),
            "connector_name": .string("Record & Replay"),
            "subtitle": .string(approvalSubtitle),
            "tool_params": .object([:])
        ])
    }

    private func toolCalled(_ name: String) {
        let snapshot = ComputerUseTelemetryContext.snapshot()
        telemetry(.toolCalled(name: name, model: snapshot.agentModel, reasoningEffort: snapshot.agentReasoningEffort))
    }

    private func approveRecording(server: Server) async throws {
        telemetry(.approvalRequested)
        let form = AcuaApprovalForm(message: Self.approvalMessage, detail: Self.approvalSubtitle,
                                    schema: .init(), meta: Self.approvalMetadata)
        let result = try await AcuaMCPElicitation.request(form, elicit: { form in
            try await server.requestElicitation(message: form.message, requestedSchema: form.schema, _meta: form.meta)
        }, serviceDialog: serviceDialog)
        switch result.action {
        case .accept:
            telemetry(.approvalResolved(action: "accepted"))
            return
        case .decline:
            telemetry(.approvalResolved(action: "declined"))
            throw EventStreamMCPToolError.recordingStartDeclined
        case .cancel:
            telemetry(.approvalResolved(action: "canceled"))
            throw EventStreamMCPToolError.recordingStartCanceled
        }
    }

    static func format(_ status: ComputerUseIPCEventStreamSessionStatus) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return .init(content: [.text(String(decoding: try encoder.encode(status), as: UTF8.self))])
    }

    func call(_ parameters: CallTool.Parameters, server: Server) async -> CallTool.Result {
        do {
            let result: ComputerUseIPCEventStreamSessionStatus
            switch parameters.name {
            case "event_stream_start":
                // Start is idempotent in the service. Even an active session
                // still goes through Start after this preliminary status read.
                let current = try await status()
                if !current.isRecording { try await approveRecording(server: server) }
                toolCalled(parameters.name)
                result = try await start()
            case "event_stream_status":
                toolCalled(parameters.name)
                result = try await status()
            case "event_stream_stop":
                toolCalled(parameters.name)
                result = try await stop(.toolStopped)
            default: throw EventStreamMCPToolError.unknownTool(parameters.name)
            }
            return try Self.format(result)
        } catch {
            return .init(content: [.text(String(describing: error))], isError: true)
        }
    }
}
