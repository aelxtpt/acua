import Foundation
import CoreFoundation

/// Which applications the agent may control, built from the `[apps]` table of
/// `~/.acua/config.toml`. Approval prompts are a separate, later step: an app
/// allowed here may still be refused by the user.
struct ComputerUsePolicy: Equatable, Sendable {
    static let defaults = ComputerUsePolicy(configuration: .defaults)

    let enabled: Bool
    let allowPersistentApproval: Bool
    private let appAccess: AcuaAppAccessConfiguration

    init(configuration: AcuaConfiguration) {
        enabled = configuration.apps.enabled
        allowPersistentApproval = configuration.apps.allowPersistentApproval
        appAccess = configuration.apps
    }

    func allows(_ bundleIdentifier: String) -> Bool {
        enabled && appAccess.access(forBundleIdentifier: bundleIdentifier) == .allow
    }
}

enum ApplicationPolicyRisk {
    static let terminalIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "co.zeit.hyper", "com.github.wez.wezterm", "org.tabby",
        "com.mitchellh.ghostty", "com.raphaelamorim.rio", "dev.commandline.waveterm"]
    static let elevatedIDs: Set<String> = ["com.apple.ScreenContinuity", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.1password.safari", "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass", "com.nordsec.nordpass", "me.proton.pass.electron", "me.proton.pass.catalyst"]
    static let warning = "Allowing the agent to use this app introduces new risks, including those related to prompt injection attacks, such as data theft or loss. Carefully monitor the agent while it uses this app."
    static func isHigh(bundleID: String, urlTypes: Any?) -> Bool {
        terminalIDs.contains(bundleID) || elevatedIDs.contains(bundleID) ||
            ((urlTypes as? [[String: Any]]) ?? []).contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("http") == true }
    }
}
