import Foundation

enum ControllerPasteFormat: UInt8, Sendable { case text, markdown, html }
struct ControllerPasteParameters: Sendable {
    let text: String
    let format: ControllerPasteFormat
    let returnAppSnapshot: Bool
}
@MainActor protocol ControllerPasteBackend {
    associatedtype Cache: Sendable
    associatedtype AppSnapshot: Sendable
    func checkCancellation() throws
    /// Paste requires the global paste queue, separate from instance queues.
    /// The concrete engine/clipboard transaction is mandatory, never a no-op.
    func globallySerializedPaste(text: String, format: ControllerPasteFormat) async throws
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle() async throws -> Cache?
    func capture(cache: Cache?) async throws -> AppSnapshot
}
@MainActor struct ControllerPasteOperation<Backend: ControllerPasteBackend> {
    let backend: Backend
    func paste(_ parameters: ControllerPasteParameters) async throws -> Backend.AppSnapshot? {
        try backend.checkCancellation()
        try await backend.globallySerializedPaste(text: parameters.text, format: parameters.format)
        // The nil branch does not write the deferred-settle flag.
        guard parameters.returnAppSnapshot else { return nil }
        backend.needsUISettleBeforeAppSnapshot = false
        let cache = try await backend.settle()
        return try await backend.capture(cache: cache)
    }
}
