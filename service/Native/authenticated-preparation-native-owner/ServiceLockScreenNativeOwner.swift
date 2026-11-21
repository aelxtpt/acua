import Foundation
import OSLog

/// Real providers, one broker and one external guardian. No fixture or granted
/// fallback enters this owner. The native helper is launched only by its client.
@MainActor final class ServiceLockScreenNativeOwner {
    static let shared = ServiceLockScreenNativeOwner()
    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "LockScreen")
    let broker: LockScreenLoginAuthorizationBroker
    private let environment: GuardianNativeEnvironment
    let loginSocket: LockScreenLoginAuthorizationSocketServer
    private lazy var components = LockScreenSharedNativeContext.host(broker: broker, environment: environment,
        isAutoUnlockEnabled: { AcuaSettings.features().lockedUse })
    var coordinator: LockScreenAutoUnlockCoordinator { components.coordinator }
    init(bundle: Bundle = .main, socketPath: String = LockScreenLoginAuthorizationSocketServer.defaultSocketPath) {
        let broker = LockScreenLoginAuthorizationBroker(); self.broker = broker
        environment = GuardianNativeEnvironment(bundle: bundle, diagnostic: { kind, pid, error in
            Self.logger.debug("Guardian \(String(describing: kind), privacy: .public), PID \(pid ?? 0): \(String(describing: error))")
        })
        loginSocket = .init(socketPath: socketPath, loginAuthorizationBrokerFactory: { broker },
            onShortWrite: { Self.logger.error("Login authorization short write: \($0)") },
            onAcceptError: { Self.logger.error("Login authorization accept error: \($0)") })
        // Use the supplied external guardian directly. The otherwise unused
        // overlay/input arguments are released, with no tap/window setup.
    }
    func start() {
        do { try loginSocket.start() }
        catch { Self.logger.error("Login authorization startup failed: \(String(describing: error))") }
    }
    func stop() { loginSocket.stop() }
}
