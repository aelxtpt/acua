import Foundation

private func controllerStopOnMain(_ controller: ControllerNativeAppController) {
    if Thread.isMainThread { MainActor.assumeIsolated { controller.deactivate() };return }
    DispatchQueue.main.sync { MainActor.assumeIsolated { controller.deactivate() } }
}
extension ControllerNativeApplicationLifecycle {
    /// Mark the supplied raw identifier before queueing. This deliberately
    /// does not resolve aliases, check forbidden targets, launch, or terminate.
    func stop(_ rawIdentifier: String) async throws -> IPCAppState {
        let instance: ControllerNativeInstanceBindings.Manager.Instance?
        do {
            instance = try await bindings.manager.stop(rawIdentifier,deactivate:{ controllerStopOnMain($0) })
        } catch {
            // Roll back the stopped reason if the queued stop fails.
            bindings.manager.clearStoppedByUser(for:rawIdentifier)
            throw error
        }
        guard let instance else { return .init(active:false,currentApp:nil) }
        // Read the current controller after its stop job has finished.
        let owner = instance.controller.owner
        return .init(active:false,currentApp:.init(pid:owner.pid,bundleIdentifier:owner.bundleIdentifier,
            appPath:owner.applicationTarget.url.path(percentEncoded:false)))
    }
}
