import Foundation

/// The delegate owns one lazy coordinator, shared by preparation and turn-end.
@MainActor final class ServiceAuthenticatedPreparationOwner {
    struct Environment {
        let resetInactivity: () -> Void
        let turnAlreadyEnded: (String) -> Bool
        let preparePIP: (String, String) -> Void
        let endPIP: (String) -> Void
        let makeCoordinator: () -> LockScreenAutoUnlockCoordinator
    }
    private let environment: Environment
    private var storedCoordinator: LockScreenAutoUnlockCoordinator?
    private var coordinator: LockScreenAutoUnlockCoordinator {
        if let storedCoordinator { return storedCoordinator }
        let value = environment.makeCoordinator(); storedCoordinator = value; return value
    }
    var hasCoordinator: Bool { storedCoordinator != nil }
    private lazy var delegate = ServiceAuthenticatedPreparation(environment: .init(
        resetInactivity: environment.resetInactivity, turnAlreadyEnded: environment.turnAlreadyEnded,
        preparePIP: environment.preparePIP,
        prepareUnlock: { [weak self] in try await self?.coordinator.prepareForRequest(threadID: $0) },
        endPIP: environment.endPIP, endUnlock: { [weak self] in self?.coordinator.agentTurnEnded(threadID: $0) }))
    init(environment: Environment) { self.environment = environment }
    func prepare(preparesTurn: Bool, allowsAutoUnlock: Bool) async throws {
        try await delegate.prepare(preparesTurn: preparesTurn, allowsAutoUnlock: allowsAutoUnlock)
    }
    func agentTurnEnded(threadID: String) { delegate.agentTurnEnded(threadID: threadID) }
}
