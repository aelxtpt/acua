import Foundation
import MCP

struct AutomationMCPAuthorization: Equatable, Sendable {
    let bundleIdentifier: String
    let requestedApproval: Bool
}

enum AutomationMCPApprovalTelemetry: Equatable, Sendable {
    case requested(tool: String?, bundleIdentifier: String?)
    case resolved(tool: String?, bundleIdentifier: String?, result: String, persistence: String?)
}

/// How the user is asked to approve an app.
enum AutomationMCPApprovalChannel: Sendable {
    /// The MCP client shows the form; it declared elicitation at initialize.
    case elicitation(AutomationMCPApproval.Elicit)
    /// ACUA only, for clients without elicitation: `[apps].allow` in
    /// `~/.acua/config.toml`, then the service's own dialog. The MCP spec
    /// forbids sending elicitation to a client that did not declare it.
    case serviceDialog(AutomationMCPApproval.ServiceDialog)
}

/// Policy is consulted on every invocation, including previously approved
/// applications. Action arguments are validated only after this gate returns.
struct AutomationMCPApproval: Sendable {
    typealias Policy = @Sendable (ComputerUseIPCAppPolicyRequest) async throws -> ComputerUseIPCAppPolicyResult
    typealias Elicit = @Sendable (CreateElicitation.Parameters.FormParameters) async throws -> CreateElicitation.Result
    typealias ServiceDialog = @Sendable (ComputerUseIPCAppApprovalRequest) async throws -> ComputerUseIPCAppApprovalResult

    let store: AppApprovalStore
    let policy: Policy
    let channel: AutomationMCPApprovalChannel
    let telemetry: @Sendable (AutomationMCPApprovalTelemetry) -> Void

    init(store: AppApprovalStore, policy: @escaping Policy, channel: AutomationMCPApprovalChannel,
         telemetry: @escaping @Sendable (AutomationMCPApprovalTelemetry) -> Void) {
        self.store = store
        self.policy = policy
        self.channel = channel
        self.telemetry = telemetry
    }

    static func form(_ policy: ComputerUseIPCAppPolicyResult) -> CreateElicitation.Parameters.FormParameters {
        var fields: [String: Value] = [:]
        if policy.allowPersistentApproval { fields["persist"] = .array([.string("always")]) }
        if policy.target.risk == .high {
            fields["riskLevel"] = .string("high")
            fields["subtitle"] = policy.target.warningSubtitle.map(Value.string)
        }
        return .init(message: "Allow the agent to use " + policy.target.displayName + "?",
            requestedSchema: .init(properties: [:]), _meta: .init(additionalFields: fields))
    }

    /// Only the exact result metadata value opts into persistence. Submitted
    /// form content, whitespace, case variants and other types do not do so.
    static func permanent(_ result: CreateElicitation.Result) -> Bool {
        result._meta?["persist"] == .string("always")
    }

    func authorize(_ tool: AutomationMCPTool, arguments: AutomationMCPArguments) async throws -> AutomationMCPAuthorization? {
        guard let app = try arguments.preflightApp(for: tool) else { return nil }
        let policy = try await policy(.init(app: app))
        let bundle = policy.target.bundleIdentifier
        switch policy.decision {
        case .denied: throw MCPToolError.appBlockedByPolicy(bundleIdentifier: bundle)
        case .forbidden: throw MCPToolError.appNotAllowed(bundleIdentifier: bundle)
        case .allowed: break
        }
        if await store.isApproved(bundle) { return .init(bundleIdentifier: bundle, requestedApproval: false) }
        switch channel {
        case .elicitation(let elicit):
            return try await elicitApproval(tool, policy: policy, elicit: elicit)
        case .serviceDialog(let dialog):
            return try await dialogApproval(tool, app: app, bundle: bundle, dialog: dialog)
        }
    }

    private func elicitApproval(_ tool: AutomationMCPTool, policy: ComputerUseIPCAppPolicyResult,
                                elicit: Elicit) async throws -> AutomationMCPAuthorization {
        let bundle = policy.target.bundleIdentifier
        telemetry(.requested(tool: tool.rawValue, bundleIdentifier: bundle))
        let result = try await elicit(Self.form(policy))
        switch result.action {
        case .decline:
            telemetry(.resolved(tool: tool.rawValue, bundleIdentifier: bundle, result: "declined", persistence: nil))
            throw MCPToolError.appApprovalDenied(bundleIdentifier: bundle)
        case .cancel:
            telemetry(.resolved(tool: tool.rawValue, bundleIdentifier: bundle, result: "canceled", persistence: nil))
            throw MCPToolError.appApprovalCanceled(bundleIdentifier: bundle)
        case .accept:
            let permanent = Self.permanent(result)
            // A forged or older peer may return always even when not offered.
            // The exact response is honored rather than revalidated.
            try await approve(bundle, permanently: permanent)
            telemetry(.resolved(tool: tool.rawValue, bundleIdentifier: bundle, result: "accepted",
                persistence: permanent ? "always" : "session"))
            return .init(bundleIdentifier: bundle, requestedApproval: true)
        }
    }

    /// `app` is the caller's identifier (bundle ID or path), so the service
    /// resolves the same app the policy check did.
    private func dialogApproval(_ tool: AutomationMCPTool, app: String, bundle: String,
                                dialog: ServiceDialog) async throws -> AutomationMCPAuthorization {
        let result = try await dialog(.init(app: app))
        switch result.decision {
        case .preApproved:
            // Nothing is stored, so removing the app from [apps].allow applies
            // to the next call.
            return .init(bundleIdentifier: bundle, requestedApproval: false)
        case .allowedForSession, .allowedAlways:
            let permanent = result.decision == .allowedAlways
            try await approve(bundle, permanently: permanent)
            telemetry(.resolved(tool: tool.rawValue, bundleIdentifier: bundle, result: "accepted",
                persistence: permanent ? "always" : "session"))
            return .init(bundleIdentifier: bundle, requestedApproval: true)
        case .denied:
            telemetry(.resolved(tool: tool.rawValue, bundleIdentifier: bundle, result: "declined", persistence: nil))
            throw MCPToolError.appApprovalDeniedInDialog(bundleIdentifier: bundle)
        case .canceled:
            telemetry(.resolved(tool: tool.rawValue, bundleIdentifier: bundle, result: "canceled", persistence: nil))
            throw MCPToolError.appApprovalCanceled(bundleIdentifier: bundle)
        }
    }

    private func approve(_ bundle: String, permanently: Bool) async throws {
        do {
            try await store.approve(bundle, permanently: permanently)
        } catch {
            throw AutomationMCPErrorWithSpanTelemetry(underlyingError: error,
                span: .init(targetID: bundle, didTriggerServerUserFlow: true))
        }
    }
}
