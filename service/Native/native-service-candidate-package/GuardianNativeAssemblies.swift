import AppKit
import Darwin

@_silgen_name("cua_guardian_invoke_startup") private func invokeNativeGuardianStartup(_ body:@convention(block) ()->Void)

@MainActor private enum GuardianHelperLoginBroker {
    static let shared = LockScreenLoginAuthorizationBroker()
}

/// Host graph uses the external helper, and shares the supplied login broker
/// with the separate login authorization socket.
@MainActor final class ExternalGuardianHostComponents<Backend: LockScreenAXBackend, E: ExternalGuardianEnvironment> {
    let broker: LockScreenLoginAuthorizationBroker
    let controller: SystemLockScreenController<SystemLockScreenAXInteractor<Backend>>
    let monitor: SystemLockScreenMonitor
    let client: ExternalLockScreenGuardianClient<E>
    let guardian: ExternalGuardianCoordinatorAdapter<E>
    let coordinator: LockScreenAutoUnlockCoordinator

    init(backend: Backend, broker: LockScreenLoginAuthorizationBroker, environment: E,
         isAutoUnlockEnabled: @escaping () -> Bool, unlockEnvironment: LockScreenUnlockEnvironment,
         observationEnvironment: LockScreenObservationEnvironment) {
        self.broker = broker
        controller = .init(environment: unlockEnvironment, accessibilityInteractor: .init(backend: backend),
                           loginAuthorizationBrokerFactory: { broker })
        monitor = .init(environment: observationEnvironment)
        client = .init(environment: environment)
        guardian = .init(client: client)
        coordinator = .init(isAutoUnlockEnabled: isAutoUnlockEnabled, controller: controller, monitor: monitor, guardian: guardian)
    }
}

/// The actual helper composition, separate from the owned test fixture. Native
/// providers are created here but used only after a real peer begins protection.
/// Event numbering and transaction ownership remain explicit until their global
/// service integration has been implemented and validated.
@MainActor struct GuardianHelperNativeDependencies {
    var nextEventNumber: () -> Int64
    var transaction: () -> LockScreenNativeAXBackend.Transaction? = { nil }
    var wallpaper: any LockScreenWallpaperProviding
    var diagnostic: @Sendable ((any Error)?) -> Void = { _ in }

    func coordinator(ignoredProcessID: Int32) -> LockScreenGuardianCoordinator {
        let broker = GuardianHelperLoginBroker.shared
        let controller = SystemLockScreenController(environment: .native(),
            accessibilityInteractor: SystemLockScreenAXInteractor(backend: LockScreenNativeAXBackend(
                nextEventNumber: nextEventNumber, transaction: transaction)), loginAuthorizationBrokerFactory: { broker })
        let monitor = SystemLockScreenMonitor(environment: .native)
        let overlay = SystemLockScreenOverlayPresenter(backend: LockScreenNativeOverlayBackend(wallpaper: wallpaper,
            profileError: diagnostic, wallpaperError: diagnostic))
        return .init(controller: controller, monitor: monitor, overlayPresenter: overlay,
                     physicalInput: SystemLockScreenPhysicalInputMonitor(ignoredProcessID: ignoredProcessID))
    }
}

@MainActor final class CUALockScreenGuardianApplicationDelegate: NSObject, NSApplicationDelegate {
    let lifecycle: GuardianHelperLifecycle
    init(arguments: [String], dependencies: GuardianHelperNativeDependencies) {
        lifecycle = .init(arguments: arguments, parentProcessID: getppid(), makeCoordinator: dependencies.coordinator,
            makeEnvironment: { GuardianServerNativeEnvironment(diagnostic: dependencies.diagnostic) },
            terminate: { NSApp.terminate(nil) }, report: dependencies.diagnostic)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        invokeNativeGuardianStartup { MainActor.assumeIsolated { self.lifecycle.applicationDidFinishLaunching() } }
    }
}

/// No test environment switch or memory-only protection path is part of this
/// entry point. Packaging its dependencies and current native acceptance remain
/// pending; validation only compiles this function.
@MainActor func runGuardianApplication(dependencies: GuardianHelperNativeDependencies) -> Int32 {
    let application = NSApplication.shared
    let delegate = CUALockScreenGuardianApplicationDelegate(arguments: CommandLine.arguments, dependencies: dependencies)
    application.delegate = delegate
    return withExtendedLifetime(delegate) { NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv) }
}
