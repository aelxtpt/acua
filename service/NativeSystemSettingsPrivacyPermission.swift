import AppKit
import ApplicationServices
import Foundation

/// Grant deliberately selects the drag fallback;
/// validation is a separate operation and may itself request screen access.
struct NativeSystemSettingsPrivacyPermission<Application: Sendable>: Sendable {
    typealias Access = SystemSettingsAccessCoordinator<Application, SettingsAccessoryCapture<NSImage>>
    enum Kind: String, Sendable {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case fullDiskAccess = "Privacy_AllFiles"
        var identifier: String { "system_settings_" + rawValue }
        var destination: SystemSettings.Destination {
            .init(paneID: SystemSettings.Destination.privacy.paneID, anchor: rawValue)
        }
    }
    struct Environment: Sendable {
        let accessibilityTrusted: @Sendable () -> Bool
        let fullDiskAccessReadable: @Sendable () -> Bool
        let onscreenWindows: @Sendable (Application) -> [SystemSettingsWindowRecord]
        let requestScreenRecording: @Sendable () -> Void
    }
    let environment: Environment

    func validate(_ kind: Kind, application: Application) -> Bool {
        switch kind {
        case .accessibility: return environment.accessibilityTrusted()
        case .fullDiskAccess: return environment.fullDiskAccessReadable()
        case .screenRecording:
            // Stop at the FIRST qualifying window, including an
            // unnamed one. An empty-but-present name still requests access.
            guard environment.onscreenWindows(application).first(where: { $0.qualifiesAsMainSettingsWindow })?.name != nil else { return false }
            environment.requestScreenRecording()
            return true
        }
    }

    @MainActor func permission(_ kind: Kind) -> Access.Permission {
        .init(identifier: kind.identifier,
              grant: { throw SystemSettingsPrivacyPermissionError.requiresUserDragAndDrop },
              privacy: .init(identifier: kind.identifier, destination: kind.destination,
                             validate: { application in validate(kind, application: application) }))
    }
}

extension NativeSystemSettingsPrivacyPermission where Application == SystemSettingsNativeApplication {
    static var native: Self {
        .init(environment: .init(accessibilityTrusted: { AXIsProcessTrusted() },
            fullDiskAccessReadable: { FileManager.default.isReadableFile(atPath: "/Library/Preferences/com.apple.TimeMachine.plist") },
            onscreenWindows: { SystemSettingsWindowRecord.nativeWindows(ownerPID: $0.processIdentifier, onscreenOnly: true) },
            requestScreenRecording: { _ = CGRequestScreenCaptureAccess() }))
    }
}

/// The service delegate supplies these activation hooks to the access
/// coordinator. Both only return on MainActor. They are the service
/// defaults, not substitutes for an unimplemented suppressor.
@MainActor enum NativeSystemSettingsActivation {
    static func prevent(_ application: SystemSettingsNativeApplication) async {}
    static func reenable() async {}
}
