import Foundation

@MainActor struct ControllerNativeAppSnapshotRequestEnvironment {
    typealias Controller = ControllerNativeAppController
    typealias Instance = ControllerNativeInstanceBindings.Manager.Instance
    let capture: (Controller, Bool) async throws -> Controller.AppSnapshot
    let blockedURL: (Controller, Controller.AppSnapshot) async -> URL?
    let scheduleFinished: (Instance) -> Void
    let instructions: (IPCApp) -> String?
    static var native: Self {
        .init(capture: { try await $0.updateAppSnapshotSettlingIfNeeded(disableAXDiffing: $1) },
            blockedURL: { controller, capture in
                // Use the application shape, not the element predicate.
                guard ControllerNativeUISettleEnvironment.native(resources: controller.resources)
                    .webShaped(controller.owner.app), let url = capture.axTree.selection.value.url else { return nil }
                // Create the checker only after both gates and use the
                // shared cache with false as the error fallback.
                let policy = EventStreamRecordingURLPolicy.local()
                return await policy.isURLBlocked(url, defaultOnError: false) ? url : nil
            }, scheduleFinished: { Self.scheduleFinished($0) }, instructions: AppSpecificInstructions.resolve)
    }
    static func scheduleFinished(_ instance: Instance,
                                 creation: ControllerNativeCursorCreationEnvironment? = nil) {
        Task { @MainActor in
            // Read the instance's current controller in the task, create a
            // cursor regardless of the feature flag, and store activity 1.
            // The base activity-state setter only stores the value.
            let cursor = instance.controller.createVirtualCursorIfNeeded(environment: creation)
            cursor.activityState = 1
        }
    }
}

@MainActor struct ControllerNativeAppSnapshotRequestBackend: ControllerAppSnapshotRequestBackend {
    typealias Capture = ControllerNativeAppController.AppSnapshot
    typealias Reply = ControllerIPCAppSnapshotResult
    let instance: ControllerNativeInstanceBindings.Manager.Instance
    let manager: ControllerNativeInstanceBindings.Manager
    let requestedIdentifier: String
    let clock: ControllerInterventionWaitClock
    let environment: ControllerNativeAppSnapshotRequestEnvironment
    func activate() { instance.controller.activate() }
    func updateActiveCount() { manager.updateActiveCount() }
    func requireNotStopped() throws { try manager.requireNotStopped(instance, requestedIdentifier: requestedIdentifier) }
    func admitStateRequery() async throws {
        try await manager.checkUserIntervention(for: instance.applicationTarget.identifier,
            requestedIdentifier: requestedIdentifier, allowsStateRequery: true, clock: clock)
    }
    func capture(disableAXDiffing: Bool) async throws -> Capture {
        try await environment.capture(instance.controller, disableAXDiffing)
    }
    func blockedURL(_ capture: Capture) async -> URL? { await environment.blockedURL(instance.controller, capture) }
    func clearInterruptionAfterRequery() {
        manager.clearUserInterruptedInterventionAfterStateRequery(for: instance.applicationTarget.identifier)
    }
    func scheduleFinishedCursor() { environment.scheduleFinished(instance) }
    func reply(_ capture: Capture) throws -> Reply {
        let owner = instance.controller.owner
        let app = IPCApp(pid: owner.pid, bundleIdentifier: owner.bundleIdentifier,
            appPath: owner.applicationTarget.url.path(percentEncoded: false))
        let instructions = environment.instructions(app)
        return try ControllerNativeAppSnapshotReply.make(app: app, capture: capture, instructions: instructions)
    }
}

extension ControllerNativeApplicationLifecycle {
    func getAppSnapshot(_ target: ComputerUseApplicationTarget, requestedIdentifier: String,
                    sender: SenderRequestContext?, disableAXDiffing: Bool,
                    requestEnvironment: ControllerNativeAppSnapshotRequestEnvironment? = nil) async throws -> ControllerIPCAppSnapshotResult {
        let instance = try await prepareInstance(target, requestedIdentifier: requestedIdentifier, sender: sender)
        let backend = ControllerNativeAppSnapshotRequestBackend(instance: instance, manager: bindings.manager,
            requestedIdentifier: requestedIdentifier, clock: environment.interventionClock,
            environment: requestEnvironment ?? .native)
        return try await instance.serialExecutor.execute {
            try await ControllerAppSnapshotRequest(backend: backend).perform(disableAXDiffing: disableAXDiffing)
        }
    }
}
