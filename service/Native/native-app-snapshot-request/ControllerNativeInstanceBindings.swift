import AppKit
import Foundation

/// Concrete native identity, activity, interruption notification and monitor
/// bindings for the canonical manager. Creating this owner starts no input tap.
/// Normal request selection and all action implementations must use this store
/// together before replacing the installed legacy routes.
final class ControllerNativeInstanceBindings: Sendable {
    typealias Manager = ControllerApplicationInstanceManager<ControllerNativeAppController>
    let monitor: ControllerUserInputMonitor
    let manager: Manager

    init(input: ControllerUserInputMonitor.Environment = ControllerNativeUserInput.environment,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        let monitor = ControllerUserInputMonitor(environment: input)
        self.monitor = monitor
        let manager = Manager(environment: .init(isActive: { $0.owner.isActive },
            isTerminated: { $0.owner.runningApplication.application.isTerminated },
            activeCountChanged: { monitor.updateActiveCount($0) },
            setCursorActivity: { controller, value in controller.owner.virtualCursor?.activityState = value },
            postUserInterruption: { controller in
                NotificationCenter.default.post(name: .init("computerUseAppControllerDidReceiveUserInterruption"), object: controller.owner)
            }, now: now, sleep: sleep))
        self.manager = manager
        monitor.setHandler { [weak manager] in manager?.receiveUserInput(for: $0) }
    }
    @MainActor func resolve(target: ComputerUseApplicationTarget, requestedIdentifier: String, create: Bool,
                            sender: SenderRequestContext?, assembly: ControllerNativeAppSnapshotBackend.Assembly) throws -> Manager.Instance {
        let configuration = ControllerRequestConfiguration(sender: sender)
        return try manager.resolve(target: target, requestedIdentifier: requestedIdentifier, create: create,
            configuration: configuration, makeController: {
                try ControllerNativeAppController(target: target, chatID: nil, mcpRuntime: configuration.mcpRuntime,
                    isAXTreeDiffingEnabled: configuration.isAXTreeDiffingEnabled, assembly: assembly)
            })
    }
    func stopMonitoring() { monitor.updateActiveCount(0) }
}
