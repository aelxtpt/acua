import Foundation
import MCP

struct CUAHistoryTelemetry: Equatable, Sendable {
    let toolName: String
    let model: String?
    let reasoningEffort: String?
    let result: String
    let durationMs: Int32
}

enum ComputerHistoryMCPToolError: Error, CustomStringConvertible {
    case unknownTool(String), invalidSettings(String)
    var description: String {
        switch self {
        case .unknownTool(let name): "Unknown tool: " + name
        case .invalidSettings(let message): message
        }
    }
}

struct CUAMCPHistory: Sendable {
    let pause: @Sendable () async throws -> ComputerUseIPCTimelineStatus
    let resume: @Sendable () async throws -> ComputerUseIPCTimelineStatus
    let status: @Sendable () async throws -> ComputerUseIPCTimelineStatus
    let getSettings: @Sendable () async throws -> ComputerUseIPCTimelineSettings
    let updateSettings: @Sendable (ComputerUseIPCTimelineSettings) async throws -> ComputerUseIPCTimelineSettings
    let telemetry: @Sendable (CUAHistoryTelemetry) -> Void
    var now: @Sendable () -> Date = Date.init

    static let tools: Set<String> = ["computer_history_pause", "computer_history_resume", "computer_history_status",
                                     "computer_history_get_settings", "computer_history_update_settings"]

    static func parseSettings(_ arguments: [String: Value]?) throws -> ComputerUseIPCTimelineSettings {
        do {
            let data = try JSONEncoder().encode(Value.object(arguments ?? [:]))
            return try JSONDecoder().decode(ComputerUseIPCTimelineSettings.self, from: data)
        } catch {
            throw ComputerHistoryMCPToolError.invalidSettings("Invalid Computer History settings: \(error)")
        }
    }

    static func format<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return .init(content: [.text(String(decoding: try encoder.encode(value), as: UTF8.self))])
    }

    static func durationMilliseconds(_ elapsed: TimeInterval) -> Int32 {
        let rounded = (elapsed * 1000).rounded(.toNearestOrAwayFromZero)
        // Convert through Int64, then clamp to a nonnegative
        // signed protobuf int32. Retain that conversion boundary.
        precondition(rounded.isFinite && rounded >= Double(Int64.min) && rounded < Double(Int64.max))
        return Int32(clamping: max(0, Int64(rounded)))
    }

    func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        let startedAt = CUAMCPInvocationContext.startedAt ?? now()
        let result: CallTool.Result
        do {
            switch parameters.name {
            case "computer_history_pause": result = try await Self.format(pause())
            case "computer_history_resume": result = try await Self.format(resume())
            case "computer_history_status": result = try await Self.format(status())
            case "computer_history_get_settings": result = try await Self.format(getSettings())
            case "computer_history_update_settings":
                let settings = try Self.parseSettings(parameters.arguments)
                result = try await Self.format(updateSettings(settings))
            default: throw ComputerHistoryMCPToolError.unknownTool(parameters.name)
            }
        } catch {
            result = .init(content: [.text(String(describing: error))], isError: true)
        }
        let snapshot = ComputerUseTelemetryContext.snapshot()
        telemetry(.init(toolName: Self.tools.contains(parameters.name) ? parameters.name : "unknown",
            model: snapshot.agentModel, reasoningEffort: snapshot.agentReasoningEffort,
            result: result.isError == true ? "failed" : "succeeded",
            durationMs: Self.durationMilliseconds(now().timeIntervalSince(startedAt))))
        return result
    }
}

extension CUAMCPHistory {
    static func native(telemetry: @escaping @Sendable (CUAHistoryTelemetry) -> Void) -> Self {
        .init(pause: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCTimelinePauseRequest(duration: nil)) },
              resume: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCTimelineResumeRequest()) },
              status: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCTimelineStatusRequest()) },
              getSettings: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCTimelineGetSettingsRequest()) },
              updateSettings: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCTimelineUpdateSettingsRequest(settings: $0)) },
              telemetry: telemetry)
    }
}
