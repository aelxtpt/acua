import Foundation

/// Bind the staged native providers to the service's existing process sequence
/// and current TaskLocal snapshot, including the same fallback cache owner.
@MainActor enum LockScreenSharedNativeContext {
    nonisolated private static func lockIdentity(_ value: EventStreamSnapshotAXIdentity) -> LockScreenAXIdentity {
        .init(element: value.element)
    }
    nonisolated private static func serviceIdentity(_ value: LockScreenAXIdentity) -> EventStreamSnapshotAXIdentity {
        .init(element: value.element)
    }
    static func nextEventNumber() -> Int64 { SynthesizedEventNumbers.shared.next() }
    static func transaction() -> LockScreenNativeAXBackend.Transaction? {
        EventStreamTreeTransactions.current?.snapshots.rekey(lockIdentity, reverse: serviceIdentity)
    }
    static func backend() -> LockScreenNativeAXBackend {
        .init(nextEventNumber: nextEventNumber, transaction: transaction)
    }
    static func helper(wallpaper: any LockScreenWallpaperProviding,
                       diagnostic: @escaping @Sendable ((any Error)?) -> Void = { _ in }) -> GuardianHelperNativeDependencies {
        .init(nextEventNumber: nextEventNumber, transaction: transaction, wallpaper: wallpaper, diagnostic: diagnostic)
    }
    static func host(broker: LockScreenLoginAuthorizationBroker, environment: GuardianNativeEnvironment,
                     isAutoUnlockEnabled: @escaping () -> Bool) -> ExternalGuardianHostComponents<LockScreenNativeAXBackend, GuardianNativeEnvironment> {
        .init(backend: backend(), broker: broker, environment: environment, isAutoUnlockEnabled: isAutoUnlockEnabled,
              unlockEnvironment: .native(), observationEnvironment: .native)
    }
}
