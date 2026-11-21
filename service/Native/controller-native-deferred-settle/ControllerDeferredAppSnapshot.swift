import Foundation

@MainActor protocol ControllerDeferredAppSnapshotBackend {
    associatedtype Cache
    associatedtype AppSnapshot
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle(delay: Double?, notificationDelay: Double, includingScrollEvents: Bool) async throws -> Cache?
    func capture(cache: Cache?, disableAXDiffing: Bool, skipScreenshot: Bool) async throws -> AppSnapshot
}

/// Consume the flag once, before any suspension. A later
/// operation can set it again while settling/capturing; do not clear it again.
@MainActor struct ControllerDeferredAppSnapshot<Backend: ControllerDeferredAppSnapshotBackend> {
    let backend: Backend
    func capture(disableAXDiffing: Bool) async throws -> Backend.AppSnapshot {
        let needsSettle = backend.needsUISettleBeforeAppSnapshot
        backend.needsUISettleBeforeAppSnapshot = false
        let cache: Backend.Cache?
        if needsSettle {
            cache = try await backend.settle(delay: nil, notificationDelay: 0.25, includingScrollEvents: false)
        } else {
            cache = nil
        }
        return try await backend.capture(cache: cache, disableAXDiffing: disableAXDiffing, skipScreenshot: false)
    }
}
