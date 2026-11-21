import AppKit

extension SystemSettingsAccessCoordinator.Environment where Application == SystemSettingsNativeApplication {
    /// Native workspace/activation/poll binding. The window record decoder,
    /// tracking, activation suppression and accessory/transition providers are
    /// supplied by their owning components; none is replaced with a no-op here.
    @MainActor static func native(
        windows: @escaping @MainActor @Sendable (Application, Bool) -> [SystemSettingsAccessCoordinator.Window],
        preventActivation: @escaping @MainActor @Sendable (Application) async -> Void,
        reenableActivation: @escaping @MainActor @Sendable () async -> Void,
        presentAccessory: @escaping @MainActor @Sendable (Application, SystemSettingsAccessCoordinator.PrivacyPermission) async throws -> Void,
        prepareTransition: @escaping @MainActor @Sendable (Capture?) -> Void,
        clearSettingsTracking: @escaping @MainActor @Sendable () -> Void,
        cleanupPresentation: @escaping @MainActor @Sendable () -> Void) -> Self {
        let opener=SystemSettingsOpener(environment:SystemSettingsOpenEnvironment<Application>.native)
        return .init(open:{ destination,activate in try await opener.open(destination,activate:activate) },
            windows:{ windows($0,false) },activate:{ _ = $0.application.activate(options:[]) },
            preventActivation:preventActivation,reenableActivation:reenableActivation,
            presentAccessory:presentAccessory,prepareTransition:prepareTransition,
            clearSettingsTracking:clearSettingsTracking,cleanupPresentation:cleanupPresentation,
            hasNoDialogs:{ SystemSettingsAccessCoordinator.hasNoDialogs(inOnscreenWindows:windows($0,true)) },
            pollUntilTrue:{ timeout,delay,condition in
                try await SystemSettingsPoll.untilTrue(timeout:timeout,delay:delay,condition:{ await condition() })
            })
    }
}
