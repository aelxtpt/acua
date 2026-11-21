import AppKit

extension SystemSettingsAccessCoordinator.Environment where Application == SystemSettingsNativeApplication {
    @MainActor static func nativeWindows(_ application: Application, onscreenOnly: Bool) -> [SystemSettingsAccessCoordinator.Window] {
        SystemSettingsWindowRecord.nativeWindows(ownerPID:application.application.processIdentifier,onscreenOnly:onscreenOnly)
            .map { .init(frame:$0.frame,isOnscreen:$0.isOnscreen) }
    }
}
