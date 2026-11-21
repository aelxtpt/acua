import ApplicationServices
import Foundation

/// The native status getters report authorized or
/// notDetermined, even when the underlying boolean is false after a denial.
enum PermissionNativeStatus {
    enum Permission: Sendable { case accessibility, screenRecording, fullDiskAccess }
    struct Environment: Sendable {
        let accessibilityTrusted: @Sendable () -> Bool
        let screenRecordingPreflight: @Sendable () -> Bool
        let fileReadable: @Sendable (String) -> Bool
        static let native = Self(accessibilityTrusted: { AXIsProcessTrusted() },
            screenRecordingPreflight: { CGPreflightScreenCaptureAccess() },
            fileReadable: { FileManager.default.isReadableFile(atPath: $0) })
    }
    static let fullDiskAccessProbePath = "/Library/Preferences/com.apple.TimeMachine.plist"
    static func read(_ permission: Permission, environment: Environment) -> PermissionWindowStatus {
        let granted: Bool
        switch permission {
        case .accessibility: granted = environment.accessibilityTrusted()
        case .screenRecording: granted = environment.screenRecordingPreflight()
        case .fullDiskAccess: granted = environment.fileReadable(fullDiskAccessProbePath)
        }
        return granted ? .authorized : .notDetermined
    }
}
