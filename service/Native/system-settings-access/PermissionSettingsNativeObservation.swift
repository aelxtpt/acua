import AppKit

extension PermissionSettingsObservation.Environment {
    @MainActor static func native(activePermissionIdentifier: @escaping @MainActor @Sendable () -> String?,
        grant: @escaping @MainActor @Sendable (Requirement) async throws -> Bool,
        completed: @escaping @MainActor @Sendable (Requirement, PermissionWindowRequestOutcome) -> Void = { _,_ in }) -> Self {
        let opener=SystemSettingsOpener(environment:SystemSettingsOpenEnvironment<SystemSettingsNativeApplication>.native)
        return .init(activePermissionIdentifier:activePermissionIdentifier,
            activationWaiter: {
                let notifications=NotificationCenter.default.notifications(named:NSApplication.didBecomeActiveNotification,object:NSApp)
                return { let iterator=notifications.makeAsyncIterator();return await iterator.next() != nil }
            },open: { destination,activate in _ = try await opener.open(destination,activate:activate) },
            applicationIsActive:{ NSApp.isActive },grant:grant,completed:completed)
    }
}
