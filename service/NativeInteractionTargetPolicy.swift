import AppKit
import ApplicationServices

enum NativeInteractionTargetPolicy {
    // The element's actual process is checked again
    // after positioning/refetch, independently of the requested app policy.
    static let systemSecurityBundles: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.LocalAuthenticationRemoteService", "com.apple.SecurityAgent"
    ]
    static func requireAllowed(bundleIdentifier: String?) throws {
        if let bundleIdentifier, systemSecurityBundles.contains(bundleIdentifier) {
            throw ServiceError(.appNotAllowed, "Computer use actions are not allowed for system security process: \(bundleIdentifier)")
        }
    }
    static func requireAllowed(element: AXUIElement) throws {
        let pid = try AccessibilityWindowSPI.actualPID(element)
        try requireAllowed(processIdentifier: pid)
    }
    static func requireAllowed(processIdentifier pid: Int32) throws {
        try requireAllowed(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }
}
