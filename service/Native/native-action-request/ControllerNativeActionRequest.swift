import Foundation

@MainActor struct ControllerNativeActionRequestEnvironment {
    typealias Controller = ControllerNativeAppController
    let focus: (Controller) -> Void
    let activity: (Controller, UInt8) -> Void
    let dispatch: (Controller, XPCAppUsageBody.Action, Bool) async throws -> Controller.AppSnapshot?
    let blockedURL: (Controller, Controller.AppSnapshot) async -> URL?
    static var native: Self {
        .init(focus: { _ = $0.owner.activateFocusEnforcer() },
            activity: { $0.createVirtualCursorIfNeeded().activityState = $1 },
            dispatch: { controller, action, capture in
                try await ControllerActionDispatch(backend: ControllerNativeActionDispatchBackend(controller: controller))
                    .perform(action, returnAppSnapshot: capture)
            }, blockedURL: ControllerNativeAppSnapshotRequestEnvironment.native.blockedURL)
    }
}

@MainActor struct ControllerNativeActionRequestBackend: ControllerActionRequestBackend {
    typealias Controller = ControllerNativeAppController
    typealias Capture = Controller.AppSnapshot
    typealias Reply = ControllerIPCActionResult
    let instance: ControllerNativeInstanceBindings.Manager.Instance
    let manager: ControllerNativeInstanceBindings.Manager
    let requestedIdentifier: String
    let clock: ControllerInterventionWaitClock
    let action: XPCAppUsageBody.Action
    let returnAppSnapshot: Bool
    let environment: ControllerNativeActionRequestEnvironment
    func requireNotStopped() throws { try manager.requireNotStopped(instance, requestedIdentifier: requestedIdentifier) }
    func admitAction() async throws {
        try await manager.checkUserIntervention(for: instance.applicationTarget.identifier,
            requestedIdentifier: requestedIdentifier, allowsStateRequery: false, clock: clock)
    }
    func controllerForAction() -> Controller { instance.controller }
    func ensureFocus(_ controller: Controller) { environment.focus(controller) }
    func setCursorActivity(_ activity: UInt8, on controller: Controller) { environment.activity(controller, activity) }
    func dispatch(on controller: Controller) async throws -> Capture? {
        try await environment.dispatch(controller, action, returnAppSnapshot)
    }
    func blockedURL(_ capture: Capture) async -> URL? { await environment.blockedURL(instance.controller, capture) }
    func reply(_ capture: Capture?) throws -> Reply {
        let owner = instance.controller.owner
        let app = IPCApp(pid: owner.pid, bundleIdentifier: owner.bundleIdentifier,
            appPath: owner.applicationTarget.url.path(percentEncoded: false))
        let appSnapshot = try capture.map { try ControllerNativeAppSnapshotReply.make(app: app, capture: $0, instructions: nil).appSnapshot }
        return .init(app: app, appSnapshot: appSnapshot)
    }
}

extension ControllerNativeApplicationLifecycle {
    func performAction(_ target: ComputerUseApplicationTarget, requestedIdentifier: String,
                       sender: SenderRequestContext?, action: XPCAppUsageBody.Action,
                       requestEnvironment: ControllerNativeActionRequestEnvironment? = nil) async throws -> ControllerIPCActionResult {
        let instance = try resolve(target, requestedIdentifier: requestedIdentifier, sender: sender, create: false)
        let backend = ControllerNativeActionRequestBackend(instance: instance, manager: bindings.manager,
            requestedIdentifier: requestedIdentifier, clock: environment.interventionClock, action: action,
            returnAppSnapshot: ControllerActionCaptureSelection.returnsAppSnapshot(sender), environment: requestEnvironment ?? .native)
        return try await instance.serialExecutor.execute { try await ControllerActionRequest(backend: backend).perform() }
    }
}
