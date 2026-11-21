import Foundation

/// The default environment composes C104's real click/settle runtime and C98's
/// native capture entry. Tests can replace those two effect boundaries while
/// still executing the controller entry, actual owner state and typed cache.
@MainActor struct ControllerNativeDeferredAppSnapshotEnvironment {
    typealias Controller = ControllerNativeAppController
    let runtime: ControllerNativeClickRuntime
    let capture: (Controller, ControllerNativeAppSnapshotCache?, Bool, Bool) async throws -> Controller.AppSnapshot
    static func native(resources: ControllerNativeResources) -> Self {
        .init(runtime: .native(resources: resources), capture: { controller, cache, disable, skip in
            try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: disable, skipScreenshot: skip)
        })
    }
}

@MainActor struct ControllerNativeDeferredAppSnapshotBackend: ControllerDeferredAppSnapshotBackend {
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let environment: ControllerNativeDeferredAppSnapshotEnvironment
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle(delay: Double?, notificationDelay: Double, includingScrollEvents: Bool) async throws -> Cache? {
        try await environment.runtime.settle(controller.owner.app, delay, notificationDelay, includingScrollEvents)
    }
    func capture(cache: Cache?, disableAXDiffing: Bool, skipScreenshot: Bool) async throws -> AppSnapshot {
        try await environment.capture(controller, cache, disableAXDiffing, skipScreenshot)
    }
}

extension ControllerNativeAppController {
    func updateAppSnapshotSettlingIfNeeded(disableAXDiffing: Bool,
        environment: ControllerNativeDeferredAppSnapshotEnvironment? = nil) async throws -> AppSnapshot {
        let backend = ControllerNativeDeferredAppSnapshotBackend(controller: self,
            environment: environment ?? .native(resources: resources))
        return try await ControllerDeferredAppSnapshot(backend: backend).capture(disableAXDiffing: disableAXDiffing)
    }
}
