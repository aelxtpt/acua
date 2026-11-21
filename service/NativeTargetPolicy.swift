import Foundation

enum NativeTargetPolicy {
    // Apps computer use never drives: terminals, where input would become
    // shell commands, and the system's notification and authentication UI.
    static let forbidden: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.alacritty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "org.tabby",
        "com.mitchellh.ghostty",
        "com.raphaelamorim.rio",
        "dev.commandline.waveterm",
        "com.apple.UserNotificationCenter",
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.SecurityAgent",
    ]

    static func isForbidden(_ bundleIdentifier: String, allowForbidden: Bool? = nil) -> Bool {
        let override = allowForbidden ?? UserDefaults.standard.bool(forKey: "ComputerUseAllowForbiddenTargets")
        return !override && forbidden.contains(bundleIdentifier)
    }

    static func requireAllowed(_ bundleIdentifier: String) throws {
        guard !isForbidden(bundleIdentifier) else {
            throw ServiceError(.appNotAllowed, "Computer use is forbidden for '\(bundleIdentifier)'")
        }
    }
}
