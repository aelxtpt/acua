import Foundation

@MainActor protocol GuardianSessionCoordinator: AnyObject {
    func setPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void)
    func setPendingUnlockPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void)
    func beginUnlockGuard(threadID: String) async throws
    func completeUnlockGuard(threadID: String, didUnlock: Bool)
    func retainAutoUnlockedLease(threadID: String)
    func releaseAutoUnlockedLease(threadID: String)
    func serviceConnectionInvalidated(onCleanupCompleted: (@MainActor () -> Void)?)
}
extension LockScreenGuardianCoordinator: GuardianSessionCoordinator {}

protocol GuardianServerConnection: AnyObject, Sendable {
    func configure(session: CUALockScreenGuardianXPCSession,
                   invalidation: @escaping @Sendable () -> Void,
                   interruption: @escaping @Sendable () -> Void)
    func activate()
    func invalidate()
    func physicalInput(error: @escaping @Sendable (any Error) -> Void) -> Bool
}

protocol GuardianServerEnvironment: AnyObject, Sendable {
    func attach(_ session: CUALockScreenGuardianXPCSession)
    func activateListener()
    func invalidateListener()
    func copySendRight(name: String) -> (UInt32, NSError?)
    func sendEndpoint(port: UInt32) -> (Bool, NSError?)
    func deallocateSendRight(_ port: UInt32)
    func report(_ error: (any Error)?)
}

// The ObjC reply is retained by one MainActor task, like an escaping-block
// wrapper. It is not independently called from multiple queues.
private final class GuardianServerReply: @unchecked Sendable {
    let body: (NSError?) -> Void
    init(_ body: @escaping (NSError?) -> Void) { self.body = body }
}

/// The connection is deliberately retained after invalidation. The helper exits
/// when coordinator cleanup completes; there is no reconnection state machine.
final class CUALockScreenGuardianXPCSession: NSObject, @unchecked Sendable {
    private enum SessionError: Error {
        case couldNotFindRendezvous, couldNotSendEndpoint, sessionUnavailable
    }
    private let environment: any GuardianServerEnvironment
    private let coordinator: any GuardianSessionCoordinator
    private let onCleanupCompleted: (@MainActor @Sendable () -> Void)?
    private let stateLock = NSLock()
    private var connection: (any GuardianServerConnection)?

    init(environment: any GuardianServerEnvironment, coordinator: any GuardianSessionCoordinator,
         onCleanupCompleted: (@MainActor @Sendable () -> Void)? = nil) {
        self.environment = environment
        self.coordinator = coordinator
        self.onCleanupCompleted = onCleanupCompleted
        super.init()
        environment.attach(self)
    }

    var hasConnection: Bool { currentConnection != nil }
    private var currentConnection: (any GuardianServerConnection)? {
        stateLock.withLock { connection }
    }

    func start(rendezvousName: String) throws {
        environment.activateListener()
        let (port, lookupError) = environment.copySendRight(name: rendezvousName)
        guard port != 0 else {
            environment.invalidateListener()
            throw lookupError ?? SessionError.couldNotFindRendezvous as NSError
        }
        defer { environment.deallocateSendRight(port) }
        let (sent, sendError) = environment.sendEndpoint(port: port)
        guard sent else {
            environment.invalidateListener()
            throw sendError ?? SessionError.couldNotSendEndpoint as NSError
        }
    }

    func accept(_ supplied: any GuardianServerConnection) -> Bool {
        guard currentConnection == nil else { return false }
        supplied.configure(session: self, invalidation: { [weak self] in self?.connectionInvalidated() },
                           interruption: { [weak self] in self?.connectionInvalidated() })
        // Activation precedes storage. Do not reserve the slot or add
        // peer credentials/generation checks across this call.
        supplied.activate()
        stateLock.withLock { connection = supplied }
        Task { @MainActor [weak self] in
            guard let self else { return }
            coordinator.setPhysicalInputHandler { [weak self] in self?.forwardPhysicalInput() }
            coordinator.setPendingUnlockPhysicalInputHandler { [weak self] in self?.pendingPhysicalInput() }
        }
        return true
    }

    func forwardPhysicalInput() {
        guard let connection = currentConnection else { environment.report(nil); return }
        let environment = environment
        if !connection.physicalInput(error: { environment.report($0) }) { environment.report(nil) }
    }

    private func pendingPhysicalInput() { currentConnection?.invalidate() }

    func connectionInvalidated() {
        environment.invalidateListener()
        Task { @MainActor [weak self] in
            guard let self else { return }
            coordinator.serviceConnectionInvalidated(onCleanupCompleted: onCleanupCompleted)
        }
    }

    func begin(threadID: String, withReply: @escaping (NSError?) -> Void) {
        let reply = GuardianServerReply(withReply)
        Task { @MainActor [weak self] in
            guard let self else { reply.body(SessionError.sessionUnavailable as NSError); return }
            do { try await coordinator.beginUnlockGuard(threadID: threadID); reply.body(nil) }
            catch { reply.body(error as NSError) }
            // Keep the session alive through the reply, including reentrancy.
            withExtendedLifetime(self) {}
        }
    }

    func complete(threadID: String, didUnlock: Bool) {
        Task { @MainActor [weak self] in self?.coordinator.completeUnlockGuard(threadID: threadID, didUnlock: didUnlock) }
    }
    func retainLease(threadID: String) {
        Task { @MainActor [weak self] in self?.coordinator.retainAutoUnlockedLease(threadID: threadID) }
    }
    func releaseLease(threadID: String) {
        Task { @MainActor [weak self] in self?.coordinator.releaseAutoUnlockedLease(threadID: threadID) }
    }
    // NSObject destruction releases fields; it does not invalidate the listener
    // or connection, cancel queued work, or invoke coordinator cleanup.
}
