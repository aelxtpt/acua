struct ServiceAuthenticatedRequestSelection: Sendable {
    let invoke: Bool
    let preparesTurn: Bool
    let allowsAutoUnlock: Bool
    init(contract: ServiceRequestContract, sender: SenderRequestContext?) {
        invoke = !contract.preparation.isPolicy && !contract.isTurnEnded
        preparesTurn = contract.preparation.preparesAgentTurn
        allowsAutoUnlock = contract.preparation.holdsActivity && (sender?.allowsLockScreenAutoUnlock ?? false)
    }
}
