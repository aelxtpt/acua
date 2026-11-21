import Foundation
import ApplicationServices

@MainActor extension LockScreenUnlockEnvironment {
    static func native() -> Self {
        let clock = ContinuousClock(), origin = ContinuousClock.now
        return .init(isAccessibilityTrusted:AXIsProcessTrusted,isLocked:SystemLockScreenSession.readLocked,
            lock:SystemLockScreenLockAction.performNative,now:{origin.duration(to:clock.now)},
            sleep:{try await Task.sleep(for:$0,clock:.continuous)})
    }
}

/// Single owner for the C53-C57 lock-screen components. Service/permission hooks,
/// native overlay and external login/guardian transport are still separate work.
@MainActor final class LockScreenAutomationComponents<Backend: LockScreenAXBackend> {
    let broker: LockScreenLoginAuthorizationBroker
    let controller: SystemLockScreenController<SystemLockScreenAXInteractor<Backend>>
    let monitor: SystemLockScreenMonitor
    let physicalInput: SystemLockScreenPhysicalInputMonitor
    let guardian: LockScreenGuardianCoordinator
    let coordinator: LockScreenAutoUnlockCoordinator

    init(backend:Backend,broker:LockScreenLoginAuthorizationBroker,isAutoUnlockEnabled:@escaping () -> Bool,
         overlayPresenter:LockScreenOverlayPresenter,unlockEnvironment:LockScreenUnlockEnvironment,
         observationEnvironment:LockScreenObservationEnvironment,physicalInput:SystemLockScreenPhysicalInputMonitor) {
        self.broker = broker; self.physicalInput = physicalInput
        let controller = SystemLockScreenController(environment:unlockEnvironment,
            accessibilityInteractor:SystemLockScreenAXInteractor(backend:backend),loginAuthorizationBrokerFactory:{broker})
        let monitor = SystemLockScreenMonitor(environment:observationEnvironment)
        let guardian = LockScreenGuardianCoordinator(controller:controller,monitor:monitor,
            overlayPresenter:overlayPresenter,physicalInput:physicalInput)
        self.controller = controller; self.monitor = monitor; self.guardian = guardian
        coordinator = LockScreenAutoUnlockCoordinator(isAutoUnlockEnabled:isAutoUnlockEnabled,
            controller:controller,monitor:monitor,guardian:guardian)
    }
}

@MainActor extension LockScreenAutomationComponents where Backend == LockScreenNativeAXBackend {
    static func native(broker:LockScreenLoginAuthorizationBroker,isAutoUnlockEnabled:@escaping () -> Bool,
                       overlayPresenter:LockScreenOverlayPresenter,nextEventNumber:@escaping () -> Int64,
                       transaction:@escaping () -> LockScreenNativeAXBackend.Transaction? = {nil}) -> Self {
        .init(backend:.init(nextEventNumber:nextEventNumber,transaction:transaction),broker:broker,
            isAutoUnlockEnabled:isAutoUnlockEnabled,overlayPresenter:overlayPresenter,
            unlockEnvironment:.native(),observationEnvironment:.native,physicalInput:.init())
    }
}
