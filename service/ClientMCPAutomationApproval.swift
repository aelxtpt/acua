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

/// Policy is consulted on every invocation, including previously approved
/// applications. Action arguments are validated only after this gate returns.
struct AutomationMCPApproval: Sendable {
    typealias Policy = @Sendable (ComputerUseIPCAppPolicyRequest) async throws -> ComputerUseIPCAppPolicyResult
    typealias Elicit = @Sendable (CreateElicitation.Parameters.FormParameters) async throws -> CreateElicitation.Result

    let store: AppApprovalStore
    let policy: Policy
    let elicit: Elicit
    let telemetry: @Sendable (AutomationMCPApprovalTelemetry) -> Void

    init(store: AppApprovalStore, policy: @escaping Policy, elicit: @escaping Elicit,
         telemetry: @escaping @Sendable (AutomationMCPApprovalTelemetry) -> Void) {
        self.store = store
        self.policy = policy
        self.elicit = elicit
        self.telemetry = telemetry
    }

    init(store: AppApprovalStore, policy: @escaping Policy, server: Server,
         telemetry: @escaping @Sendable (AutomationMCPApprovalTelemetry) -> Void) {
        self.init(store: store, policy: policy, elicit: { parameters in
            try await server.requestElicitation(message: parameters.message, mode: parameters.mode,
                requestedSchema: parameters.requestedSchema, _meta: parameters._meta)
        }, telemetry: telemetry)
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
}
