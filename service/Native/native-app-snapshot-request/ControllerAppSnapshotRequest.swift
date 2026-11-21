import Foundation

enum ControllerAppSnapshotRequestFailure: Error, Equatable {
    case blockedURL(URL)
    case missingScreenshotMIMEType
}

@MainActor protocol ControllerAppSnapshotRequestBackend {
    associatedtype Capture
    associatedtype Reply
    func activate()
    func updateActiveCount()
    func requireNotStopped() throws
    func admitStateRequery() async throws
    func capture(disableAXDiffing: Bool) async throws -> Capture
    func blockedURL(_ capture: Capture) async -> URL?
    func clearInterruptionAfterRequery()
    func scheduleFinishedCursor()
    func reply(_ capture: Capture) throws -> Reply
}

/// Activation/count precede the queued stopped check, admission permits a
/// state requery, and policy rejection leaves interruption intact. The
/// finished-cursor task is scheduled before formatting, without awaiting it.
@MainActor struct ControllerAppSnapshotRequest<Backend: ControllerAppSnapshotRequestBackend> {
    let backend: Backend
    func perform(disableAXDiffing: Bool) async throws -> Backend.Reply {
        backend.activate()
        backend.updateActiveCount()
        try backend.requireNotStopped()
        try await backend.admitStateRequery()
        let capture = try await backend.capture(disableAXDiffing: disableAXDiffing)
        if let url = await backend.blockedURL(capture) { throw ControllerAppSnapshotRequestFailure.blockedURL(url) }
        backend.clearInterruptionAfterRequery()
        backend.scheduleFinishedCursor()
        return try backend.reply(capture)
    }
}
