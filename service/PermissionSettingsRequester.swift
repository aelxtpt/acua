import Foundation

/// Permission window request outcome adapter and
/// weak per-row transition callbacks around the shared access coordinator.
@MainActor final class PermissionSettingsRequester<Requirement: Hashable & Sendable, Application: Sendable, Capture: Sendable> {
    typealias Access=SystemSettingsAccessCoordinator<Application,Capture>
    struct Environment: Sendable {
        let sourceCapture: @MainActor @Sendable (Requirement) -> Capture?
        let activateApplication: @MainActor @Sendable () -> Void
        var requestAlreadyActive: @MainActor @Sendable (String) -> Void = { _ in }
        var failed: @MainActor @Sendable (any Error) -> Void = { _ in }
    }
    weak var controller: PermissionWindowCoordinator<Requirement>?
    let access: Access
    let environment: Environment
    init(controller: PermissionWindowCoordinator<Requirement>, access: Access, environment: Environment) {
        self.controller=controller;self.access=access;self.environment=environment
    }
    func request(_ permission: Access.Permission, for requirement: Requirement) async -> PermissionWindowRequestOutcome {
        guard let controller else { return .failed }
        if let active=access.activePermissionIdentifier { environment.requestAlreadyActive(active);return .failed }
        access.onAccessoryTransitionStart={ [weak controller] in controller?.accessoryTransitionStarted(for:requirement) }
        access.onAccessoryReverseTransitionCompletion={ [weak controller] in controller?.accessoryTransitionCompleted(for:requirement) }
        defer {
            // No generation guard when clearing these shared hooks.
            access.onAccessoryTransitionStart=nil;access.onAccessoryReverseTransitionCompletion=nil
            controller.accessoryTransitionCompleted(for:requirement)
        }
        controller.window.currentWindow()?.setLevel(0)
        let capture=environment.sourceCapture(requirement)
        do { return try await access.requestAccess(to:permission,sourceCapture:capture) ? .granted:.denied }
        catch SystemSettingsPrivacyPermissionError.userCancelled {
            environment.activateApplication();return .cancelled
        } catch is CancellationError { return .cancelled }
        catch let error as Access.RequestError {
            if case let .requestAlreadyInProgress(identifier)=error { environment.requestAlreadyActive(identifier) }
            return .failed
        } catch { environment.failed(error);return .failed }
    }
}
