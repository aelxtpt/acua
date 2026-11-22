import Foundation

/// Application policy for every request path (policy query, app check, global
/// check). The policy comes from `~/.acua/config.toml` and is read on each call,
/// so edits apply to the next request without restarting the service.
enum ComputerUsePolicyIPC {
    static func perform(_ identifier: String) throws -> JSON {
        // Resolving the target first keeps the lookup error when both the app
        // and the configuration are invalid.
        let target = try Policy.target(for: identifier)
        return Policy.render(target: target, policy: try policy())
    }

    static func requireApplicationAllowed(_ identifier: String) throws {
        let target = try Policy.target(for: identifier)
        let value = try policy()
        try ServiceRequestPolicyDecision.requireApplication(target.bundleIdentifier, policy: value,
            forbidden: { NativeTargetPolicy.isForbidden(target.bundleIdentifier) })
    }

    static func requireEnabled() throws {
        try ServiceRequestPolicyDecision.requireEnabled(policy())
    }

    private static func policy() throws -> ComputerUsePolicy {
        ComputerUsePolicy(configuration: try configuration())
    }

    static func configuration() throws -> AcuaConfiguration {
        do {
            return try AcuaConfigurationLoader().load()
        } catch let error as AcuaConfigurationError {
            // An invalid file fails closed: no request runs on a guessed policy.
            throw ServiceError(.unknownError, "Computer Use configuration is invalid: \(error.description)")
        }
    }
}
