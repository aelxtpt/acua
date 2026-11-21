import Foundation
import MCP

enum AutomationMCPMetricName: String, CaseIterable, Sendable {
    case timeToFirstGetAppState = "computer_use_mcp_time_to_first_get_app_state"
    case timeToFirstWrite = "computer_use_mcp_time_to_first_write"
    case timeFromStartOfFirstSuccessfulGetAppStateToFirstWrite = "computer_use_mcp_time_from_first_get_app_state_to_first_write"
    case timeFromEndOfFirstSuccessfulGetAppStateToFirstWrite = "computer_use_mcp_time_from_end_of_first_successful_get_app_state_to_first_write"
}

/// Metric content is independent of the logger and tracker lifecycle.
struct AutomationMCPMetricEmission: Sendable {
    let metricName: AutomationMCPMetricName
    let durationMilliseconds: Int
    let bundleIdentifier: String?
    let toolName: AutomationMCPTool?
    let listAppsCalled: Bool
    let approvalRequested: Bool
    let userInputRequestedDuringTurn: Bool

    var properties: [String: Value] {
        var result: [String: Value] = [
            "duration_ms": .int(durationMilliseconds),
            "list_apps_called": .bool(listAppsCalled),
            "approval_requested": .bool(approvalRequested),
            "user_input_requested_during_turn": .bool(userInputRequestedDuringTurn)
        ]
        if let bundleIdentifier { result["bundle_identifier"] = .string(bundleIdentifier) }
        if let toolName { result["tool_name"] = .string(toolName.rawValue) }
        return result
    }
}

enum AutomationMCPMetricDuration {
    // Checked integer conversion/subtraction is used. Invalid dates
    // and overflow trap; a negative, representable duration returns nil.
    static func sinceTurnStart(_ date: Date, unixMilliseconds: Int64?) -> Int? {
        guard let unixMilliseconds else { return nil }
        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.toNearestOrAwayFromZero))
        let duration = milliseconds - unixMilliseconds
        return duration < 0 ? nil : Int(duration)
    }

    static func between(_ start: Date, and end: Date) -> Int? {
        let duration = Int((end.timeIntervalSince(start) * 1_000).rounded(.toNearestOrAwayFromZero))
        return duration < 0 ? nil : duration
    }
}
