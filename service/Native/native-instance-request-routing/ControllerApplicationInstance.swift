import Foundation

/// Each canonical target gets one controller and one independent queue.
/// Replacing a controller does not replace the instance's pending task chain.
final class ControllerApplicationInstance<Controller: Sendable>: @unchecked Sendable {
    let applicationTarget: ComputerUseApplicationTarget
    let configuration: ControllerRequestConfiguration
    let serialExecutor = ControllerInstanceSerialExecutor()
    private let lock = NSLock()
    private var storedController: Controller

    init(target: ComputerUseApplicationTarget, configuration: ControllerRequestConfiguration, controller: Controller) {
        applicationTarget = target; self.configuration = configuration; storedController = controller
    }
    var controller: Controller {
        get { lock.withLock { storedController } }
        set {
            let previous = lock.withLock { let previous = storedController; storedController = newValue; return previous }
            withExtendedLifetime(previous) {}
        }
    }
}
