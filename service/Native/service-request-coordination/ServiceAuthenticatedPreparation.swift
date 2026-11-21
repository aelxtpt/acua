import Foundation

/// App-delegate preparation callback. Metadata is read from the active task at
/// each snapshot boundary, including after asynchronous operations.
@MainActor final class ServiceAuthenticatedPreparation {
    struct Environment {
        var resetInactivity: () -> Void
        var turnAlreadyEnded: (String) -> Bool
        var preparePIP: (String, String) -> Void
        var prepareUnlock: (String?) async throws -> Void
        var endPIP: (String) -> Void
        var endUnlock: (String) -> Void
    }
    let environment: Environment
    init(environment: Environment) { self.environment = environment }
    func prepare(preparesTurn: Bool, allowsAutoUnlock: Bool) async throws {
        environment.resetInactivity()
        let turnMetadata = ComputerUseTelemetryContext.snapshot()
        if preparesTurn, let turn = turnMetadata.agentTurnID {
            guard !environment.turnAlreadyEnded(turn) else {
                throw ServiceError(.agentTurnAlreadyEnded,
                    "Computer Use is unavailable because the current turn ended. It will work again after the next user message.")
            }
            if let thread = turnMetadata.agentSessionID {
                environment.preparePIP(thread, turn)
            }
        }
        if allowsAutoUnlock {
            let unlockMetadata = ComputerUseTelemetryContext.snapshot()
            try await environment.prepareUnlock(unlockMetadata.agentSessionID)
        }
    }

    /// The on-turn-ended callback is separate from dispatch of the ended request.
    /// It does not release a lease merely because a single request returned.
    func agentTurnEnded(threadID: String) {
        environment.endPIP(threadID)
        environment.endUnlock(threadID)
    }
}

@MainActor extension ServiceAuthenticatedPreparation.Environment {
    static func lockScreen(coordinator: LockScreenAutoUnlockCoordinator,
        resetInactivity: @escaping () -> Void, turnAlreadyEnded: @escaping (String) -> Bool,
        preparePIP: @escaping (String, String) -> Void,
        endPIP: @escaping (String) -> Void) -> Self {
        .init(resetInactivity: resetInactivity, turnAlreadyEnded: turnAlreadyEnded,
            preparePIP: preparePIP, prepareUnlock: { try await coordinator.prepareForRequest(threadID: $0) },
            endPIP: endPIP, endUnlock: coordinator.agentTurnEnded)
    }
}
