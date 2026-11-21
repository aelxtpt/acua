import Foundation

@MainActor protocol ControllerActionRequestBackend {
    associatedtype Controller
    associatedtype Capture
    associatedtype Reply
    func requireNotStopped() throws
    func admitAction() async throws
    func controllerForAction() -> Controller
    func ensureFocus(_ controller: Controller)
    func setCursorActivity(_ activity: UInt8, on controller: Controller)
    func dispatch(on controller: Controller) async throws -> Capture?
    func blockedURL(_ capture: Capture) async -> URL?
    func reply(_ capture: Capture?) throws -> Reply
}

/// No activation, interruption clearing, or error-path finished-cursor defer.
@MainActor struct ControllerActionRequest<Backend: ControllerActionRequestBackend> {
    let backend: Backend
    func perform() async throws -> Backend.Reply {
        try backend.requireNotStopped()
        try await backend.admitAction()
        let controller = backend.controllerForAction()
        backend.ensureFocus(controller)
        backend.setCursorActivity(0, on: controller)
        let capture = try await backend.dispatch(on: controller)
        if let capture, let url = await backend.blockedURL(capture) {
            throw ControllerAppSnapshotRequestFailure.blockedURL(url)
        }
        // This MainActor phase runs on the captured controller.
        backend.setCursorActivity(1, on: controller)
        return try backend.reply(capture)
    }
}

struct ControllerIPCActionResult: Codable, Equatable, Sendable {
    let app: IPCApp
    let appSnapshot: ControllerIPCAppSnapshot?
}

enum ControllerActionCaptureSelection {
    // Optional sender presence and clientType's high word only.
    // MCP runtime is independent. These booleans are captured before queueing.
    static func returnsAppSnapshot(_ sender: SenderRequestContext?) -> Bool {
        sender?.clientMetadata.clientType != .nodeRepl
    }
}
