import Foundation

enum ServiceRequestPolicyDecision {
    static func requireEnabled(_ policy: ComputerUsePolicy) throws {
        guard policy.enabled else {
            // A disabled configuration is reported as an unknown error (code 5).
            throw ServiceError(.unknownError, "Computer Use is disabled by your configuration.")
        }
    }
    static func requireApplication(_ bundleIdentifier: String, policy: ComputerUsePolicy,
                                   forbidden: () -> Bool) throws {
        guard policy.allows(bundleIdentifier), !forbidden() else {
            // A denied app is reported as appNotAllowed.
            throw ServiceError(.appNotAllowed,
                "Computer Use is not allowed to use the app '\(bundleIdentifier)' for safety reasons.")
        }
    }
}
