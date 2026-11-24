import Foundation

/// The app an MCP client asks to use, as resolved by the service.
struct AcuaAppApprovalTarget: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    /// Set for high-risk apps (terminals, password managers, browsers).
    let warningSubtitle: String?
}

/// What the native approval dialog shows.
struct AcuaAppApprovalPrompt: Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
    let warning: String?
    let offersAlwaysAllow: Bool
}

/// The button the user chose. `dismissed` covers a timeout and a dialog that
/// could not be shown.
enum AcuaAppApprovalAnswer: Sendable {
    case allowForSession
    case alwaysAllow
    case deny
    case dismissed
}

/// Wire value of `ComputerUseIPCAppApprovalRequest`. The client mirrors it in
/// `ComputerUseIPCAppApprovalDecision`.
enum AcuaAppApprovalDecision: String, Codable, Sendable {
    /// Listed in `[apps].allow`: no dialog, and the client keeps no approval,
    /// so removing the app from the list applies to the next call.
    case preApproved = "pre_approved"
    case allowedForSession = "allowed_for_session"
    case allowedAlways = "allowed_always"
    case denied
    case canceled
}

/// Approval for MCP clients that cannot show an elicitation form. Apps the
/// user listed in `[apps].allow` pass without asking; any other app asks the
/// user through the service's own dialog.
struct AcuaAppApprover {
    let prompt: (AcuaAppApprovalPrompt) -> AcuaAppApprovalAnswer

    func decide(_ target: AcuaAppApprovalTarget, apps: AcuaAppAccessConfiguration) -> AcuaAppApprovalDecision {
        // The policy check runs before this in the service. Repeating it here
        // keeps a denied app from ever reaching the dialog.
        guard apps.enabled, apps.access(forBundleIdentifier: target.bundleIdentifier) == .allow else {
            return .denied
        }

        if apps.isExplicitlyAllowed(target.bundleIdentifier) {
            return .preApproved
        }

        let answer = prompt(.init(displayName: target.displayName, bundleIdentifier: target.bundleIdentifier,
                                  warning: target.warningSubtitle, offersAlwaysAllow: apps.allowPersistentApproval))
        switch answer {
        case .allowForSession:
            return .allowedForSession
        case .alwaysAllow:
            // Only honored when the dialog offered it.
            return apps.allowPersistentApproval ? .allowedAlways : .allowedForSession
        case .deny:
            return .denied
        case .dismissed:
            return .canceled
        }
    }
}
