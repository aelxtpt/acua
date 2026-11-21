import Foundation

/// The three observation options: no wait, next application activation, or the
/// permission-grant loop. Only tag 1 permits settings termination.
enum PermissionSettingsObservationMode: UInt8, Sendable { case none, nextActivation, permissionGrant }

@MainActor final class PermissionSettingsObservation<Requirement: Hashable & Sendable> {
    struct Environment: Sendable {
        let activePermissionIdentifier: @MainActor @Sendable () -> String?
        let activationWaiter: @MainActor @Sendable () -> PermissionWindowCloseWaiter
        let open: @MainActor @Sendable (SystemSettings.Destination, Bool) async throws -> Void
        let applicationIsActive: @MainActor @Sendable () -> Bool
        let grant: @MainActor @Sendable (Requirement) async throws -> Bool
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for:$0) }
        var blocked: @MainActor @Sendable (String) -> Void = { _ in }
        // This reports settings telemetry. It is NOT the permission-request
        // callback that changes C63's shared grant state.
        var completed: @MainActor @Sendable (Requirement, PermissionWindowRequestOutcome) -> Void = { _,_ in }
    }
    weak var controller: PermissionWindowCoordinator<Requirement>?
    let environment: Environment
    init(controller: PermissionWindowCoordinator<Requirement>, environment: Environment) {
        self.controller=controller;self.environment=environment
    }
    @discardableResult func open(_ destination: SystemSettings.Destination, for requirement: Requirement,
                                mode: PermissionSettingsObservationMode) -> UUID? {
        guard let controller else { return nil }
        let environment=environment
        if let active=environment.activePermissionIdentifier() { environment.blocked(active);return nil }
        return controller.beginObservation(for:requirement,allowsSettingsTermination:mode == .nextActivation,
            makeCancellation: { id in
                // Construct this sequence for all modes, even no wait.
                let activation=environment.activationWaiter()
                let task=Task { @MainActor [weak controller] in
                    guard let controller else { return }
                    controller.window.currentWindow()?.setLevel(0)
                    do {
                        try await environment.open(destination,true)
                        switch mode {
                        case .none: break
                        case .nextActivation: _ = await activation()
                        case .permissionGrant:
                            await Self.poll(requirement,controller:controller,environment:environment)
                        }
                        let status=controller.environment.status(requirement)
                        environment.completed(requirement,status == .authorized ? .granted:.denied)
                    } catch {
                        environment.completed(requirement,.failed)
                        controller.refresh()
                    }
                    controller.finishObservation(for:requirement,id:id)
                }
                return { task.cancel() }
            })
    }
    private static func poll(_ requirement: Requirement, controller: PermissionWindowCoordinator<Requirement>,
                             environment: Environment) async {
        var previousActive=environment.applicationIsActive()
        while !Task.isCancelled {
            guard controller.window.currentWindow()?.isVisible == true else { return }
            let active=environment.applicationIsActive()
            if !previousActive && active { _ = try? await environment.grant(requirement) }
            previousActive=active
            controller.refresh()
            if controller.state.statuses[requirement] == .authorized { return }
            do { try await environment.sleep(.milliseconds(250)) }
            catch { return }
        }
    }
}
