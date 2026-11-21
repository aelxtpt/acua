import Foundation

// Approval events raised by the Messages MCP server. ACUA sends no analytics,
// so they are dropped (see DiscardedTelemetry), but the approval flow still
// reports them so tests can observe each decision.
enum CUAMessagesApprovalOperation: Int, Sendable {
    case unspecified, readMessages, searchMessages, readImage, sendMessage
}

enum CUAMessagesApprovalResult: Int, Sendable {
    case unspecified, accepted, declined, canceled, error
}

enum CUAMessagesApprovalPersistence: Int, Sendable {
    case unspecified, once, turn, session, always
}

enum CUAMessagesApprovalTelemetry: Sendable {
    case requested(operation: CUAMessagesApprovalOperation?, chatCount: Int64?)
    case resolved(operation: CUAMessagesApprovalOperation?, result: CUAMessagesApprovalResult?,
                  persistence: CUAMessagesApprovalPersistence?, chatCount: Int64?)
}
