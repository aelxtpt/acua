import Foundation

struct ComputerUseIPCDiscoveredApp: Codable, Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
    let appPath: String?
    let lastUsedDate: Date?
    let useCount: Int?
    let isRunning: Bool
    let isFrontmost: Bool
}

struct ComputerUseIPCFrontmostWindow: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
    let windowTitle: String?
}

enum ComputerUseIPCTargetRisk: String, Codable, Sendable { case low, high }
enum ComputerUseIPCAppPolicyDecision: String, Codable, Sendable { case allowed, denied, forbidden }

struct ComputerUseIPCTargetDescriptor: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let appPath: String
    let risk: ComputerUseIPCTargetRisk
    let warningSubtitle: String?
}

struct ComputerUseIPCAppPolicyResult: Codable, Equatable, Sendable {
    let decision: ComputerUseIPCAppPolicyDecision
    let target: ComputerUseIPCTargetDescriptor
    let allowPersistentApproval: Bool
    /// The app is listed in
    /// `[apps].allow`, so no client asks for approval.
    var preApproved: Bool? = nil
}

enum ComputerUseIPCEventStreamEndReason: String, Codable, Sendable {
    case toolStopped = "tool_stopped"
    case debugUIStopped = "debug_ui_stopped"
    case recordingControlsStopped = "recording_controls_stopped"
    case recordingControlsCancelled = "recording_controls_cancelled"
    case maxDuration = "max_duration"
    case serviceTerminated = "service_terminated"
}

struct ComputerUseIPCEventStreamSessionStatus: Codable, Equatable, Sendable {
    let isRecording: Bool
    let sessionID: String?
    let sessionDirectoryPath: String?
    let eventsPath: String?
    let metadataPath: String?
    let suppressedEventsPath: String?
    let startedAt: Date?
    let endedAt: Date?
    let endReason: ComputerUseIPCEventStreamEndReason?
    let maxDurationSeconds: Int
}

struct ComputerUseIPCListAppsRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = [ComputerUseIPCDiscoveredApp]
}
struct ComputerUseIPCFrontmostWindowRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCFrontmostWindow?
}
struct ComputerUseIPCEventStreamStatusRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCEventStreamSessionStatus
}
struct ComputerUseIPCAppPolicyRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppPolicyResult
    let app: String
}

/// Mirrors the service's
/// `AcuaAppApprovalDecision`.
enum ComputerUseIPCAppApprovalDecision: String, Codable, Sendable {
    /// Listed in `[apps].allow`; the client stores no approval.
    case preApproved = "pre_approved"
    case allowedForSession = "allowed_for_session"
    case allowedAlways = "allowed_always"
    case denied
    case canceled
}

struct ComputerUseIPCAppApprovalResult: Codable, Equatable, Sendable {
    let decision: ComputerUseIPCAppApprovalDecision
}

/// Asks the service to approve an app for an MCP client that cannot show an
/// elicitation form: `[apps].allow`, then the service's dialog.
struct ComputerUseIPCAppApprovalRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppApprovalResult
    let app: String
}
