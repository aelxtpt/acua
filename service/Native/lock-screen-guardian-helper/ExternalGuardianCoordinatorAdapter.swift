import Foundation

/// Maps the host's pending-input requirement to the
/// external client's connection-loss handler. The helper invalidates its link
/// when physical input interrupts a pending guard.
@MainActor final class ExternalGuardianCoordinatorAdapter<E: ExternalGuardianEnvironment>: LockScreenGuardian {
    let client: ExternalLockScreenGuardianClient<E>
    init(client: ExternalLockScreenGuardianClient<E>) { self.client = client }
    func setPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) { client.physicalInputHandler = handler }
    func setPendingUnlockPhysicalInputHandler(_ handler: @escaping @MainActor () -> Void) { client.connectionLossHandler = handler }
    func withUnlockGuard(threadID: String, perform: @escaping @MainActor () async throws -> Bool) async throws -> Bool {
        await client.withUnlockGuardOrFalse(threadID: threadID, perform: perform)
    }
    func retainAutoUnlockedLease(threadID: String) { client.retainAutoUnlockedLease(threadID: threadID) }
    func releaseAutoUnlockedLease(threadID: String) { client.releaseAutoUnlockedLease(threadID: threadID) }
}
