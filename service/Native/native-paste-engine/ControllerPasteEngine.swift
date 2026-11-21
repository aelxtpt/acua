import Foundation

enum ControllerPasteEngineFailure: Int, Error, Equatable {
    case failedToProvideData = 4
    case unread = 5
    case ownershipLost = 6
}

@MainActor protocol ControllerPasteEngineBackend {
    associatedtype Observation
    associatedtype Session
    func ensureInitialFocus() throws
    func observe() throws -> Observation
    func stop(_ observation: Observation)
    func prepare(text: String, format: ControllerPasteFormat, observation: Observation) async throws -> Session
    func markDispatched(_ observation: Observation)
    func enforceKeyboardFocus() async throws
    func sendPasteShortcut() async throws
    func markNeedsUISettle()
    func waitForRead(_ session: Session, timeout: Duration) async throws -> Bool
    func checkCancellation() throws
    func ownsGeneration(_ session: Session) -> Bool
    func pollAcknowledgement(_ session: Session, observation: Observation, timeout: Double, delay: Double) async throws -> Bool
    func failedToProvideData(_ session: Session) -> Bool
    func restore(_ session: Session) -> Bool
}

/// Only the acknowledgement block handles reason 5 specially.
/// All post-prepare errors attempt restoration and preserve their error identity.
@MainActor struct ControllerPasteEngine<Backend: ControllerPasteEngineBackend> {
    let backend: Backend
    func paste(text: String, format: ControllerPasteFormat) async throws {
        try backend.ensureInitialFocus()
        let observation = try backend.observe()
        defer { backend.stop(observation) }
        let session = try await backend.prepare(text:text,format:format,observation:observation)
        do {
            backend.markDispatched(observation)
            try await backend.enforceKeyboardFocus()
            try await backend.sendPasteShortcut()
            backend.markNeedsUISettle()
            do {
                let read = try await backend.waitForRead(session,timeout:.seconds(2))
                try backend.checkCancellation()
                guard read else { throw ControllerPasteEngineFailure.unread }
                guard backend.ownsGeneration(session) else { throw ControllerPasteEngineFailure.ownershipLost }
                let owned = try await backend.pollAcknowledgement(session,observation:observation,timeout:2,delay:0.025)
                try backend.checkCancellation()
                guard owned else { throw ControllerPasteEngineFailure.ownershipLost }
            } catch ControllerPasteEngineFailure.unread {
                try backend.checkCancellation()
                guard !backend.failedToProvideData(session) else { throw ControllerPasteEngineFailure.failedToProvideData }
                try backend.checkCancellation()
                guard backend.restore(session) else { throw ControllerPasteEngineFailure.ownershipLost }
            }
        } catch {
            _ = backend.restore(session)
            throw error
        }
    }
}
