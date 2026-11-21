import Foundation

enum ControllerNativeApplicationLifecycleError: Error, Equatable {
    case forbiddenTarget(String)
}

/// The lifecycle facade uses the canonical native manager and each instance's
/// existing executor. No second AppSessions store or controller is introduced.
@MainActor struct ControllerNativeApplicationLifecycle {
    typealias Manager = ControllerNativeInstanceBindings.Manager
    typealias Instance = Manager.Instance
    @MainActor struct Environment {
        let prepareLaunch: @MainActor (ComputerUseApplicationTarget) async throws -> Void
        let makeController: @MainActor (ComputerUseApplicationTarget, ControllerRequestConfiguration) throws -> ControllerNativeAppController
        let interventionClock: ControllerInterventionWaitClock
        static func native(assembly: ControllerNativeAppSnapshotBackend.Assembly,
                           launch: ControllerNativeLaunchEnvironment? = nil) -> Self {
            let backend = ControllerNativeLaunchBackend(resources: assembly.resources,
                environment: launch ?? .native(resources: assembly.resources))
            return .init(prepareLaunch: { try await ControllerLaunchPreparation(backend: backend).prepare($0) },
                makeController: { target, configuration in
                    try .init(target: target, chatID: nil, mcpRuntime: configuration.mcpRuntime,
                        isAXTreeDiffingEnabled: configuration.isAXTreeDiffingEnabled, assembly: assembly)
                }, interventionClock: .native)
        }
    }
    let bindings: ControllerNativeInstanceBindings
    let environment: Environment
    private var manager: Manager { bindings.manager }
    func resolve(_ target: ComputerUseApplicationTarget, requestedIdentifier: String,
                         sender: SenderRequestContext?, create: Bool) throws -> Instance {
        guard !NativeTargetPolicy.forbidden.contains(target.bundleIdentifier) else {
            throw ControllerNativeApplicationLifecycleError.forbiddenTarget(target.bundleIdentifier)
        }
        let configuration = ControllerRequestConfiguration(sender: sender)
        return try manager.resolve(target: target, requestedIdentifier: requestedIdentifier, create: create,
            configuration: configuration, makeController: { try environment.makeController(target, configuration) })
    }
    func prepareInstance(_ target: ComputerUseApplicationTarget, requestedIdentifier: String,
                         sender: SenderRequestContext?) async throws -> Instance {
        guard !NativeTargetPolicy.forbidden.contains(target.bundleIdentifier) else {
            throw ControllerNativeApplicationLifecycleError.forbiddenTarget(target.bundleIdentifier)
        }
        try await environment.prepareLaunch(target)
        return try resolve(target, requestedIdentifier: requestedIdentifier, sender: sender, create: true)
    }
    /// Launch before instance resolution. Stopped-state checks therefore
    /// remain after launch preparation, including a possible launch side effect.
    func start(_ target: ComputerUseApplicationTarget, requestedIdentifier: String,
               sender: SenderRequestContext?) async throws -> IPCAppState {
        let instance = try await prepareInstance(target, requestedIdentifier: requestedIdentifier, sender: sender)
        let manager = self.manager
        return try await instance.serialExecutor.execute {
            await MainActor.run {
                instance.controller.activate()
                manager.updateActiveCount()
                return state(instance)
            }
        }
    }
    /// Keep deactivation distinct from a stopped session. Deactivation
    /// removes the instance and clears interruption but does not set the
    /// stopped reason or terminate the native application.
    func modify(_ target: ComputerUseApplicationTarget, requestedIdentifier: String,
                sender: SenderRequestContext?, deactivate: Bool) async throws -> IPCAppState {
        let instance = try resolve(target, requestedIdentifier: requestedIdentifier, sender: sender, create: false)
        let manager = self.manager, clock = environment.interventionClock
        return try await instance.serialExecutor.execute {
            if deactivate {
                return await MainActor.run {
                    instance.controller.deactivate()
                    manager.updateActiveCount()
                    manager.clearUserInterruptedIntervention(for: instance.applicationTarget.identifier)
                    manager.removeInstance(for: instance.applicationTarget.identifier)
                    return state(instance)
                }
            }
            try await MainActor.run { try manager.requireNotStopped(instance, requestedIdentifier: requestedIdentifier) }
            try await manager.checkUserIntervention(for: instance.applicationTarget.identifier,
                requestedIdentifier: requestedIdentifier, allowsStateRequery: false, clock: clock)
            return await MainActor.run {
                instance.controller.activate()
                manager.updateActiveCount()
                return state(instance)
            }
        }
    }
    private func state(_ instance: Instance) -> IPCAppState {
        // Read controller identity again after the active snapshot.
        let active = instance.controller.owner.isActive
        let owner = instance.controller.owner
        return .init(active: active, currentApp: .init(pid: owner.pid,
            bundleIdentifier: owner.bundleIdentifier, appPath: owner.applicationTarget.url.path(percentEncoded: false)))
    }
}
