import Foundation

struct AutomationMCPMetricsToolCall: Sendable {
    let toolName: AutomationMCPTool
    let bundleIdentifier: String?
    let agentSessionID: String?
    let agentTurnID: String?
    let turnStartedAtUnixMilliseconds: Int64?
    let approvalRequested: Bool
    let userInputRequestedDuringTurn: Bool?
    let receivedAt: Date
}

protocol AutomationMCPTurnMetricsTracking: Sendable {
    func record(_ call: AutomationMCPMetricsToolCall) async
    func recordSuccessfulGetAppState(_ call: AutomationMCPMetricsToolCall, endedAt: Date) async
}

actor AutomationMCPTurnMetricsTracker: AutomationMCPTurnMetricsTracking {
    private struct TurnKey: Hashable {
        let sessionID: String?
        let turnID: String
    }

    private struct TurnState {
        var turnStartedAtUnixMilliseconds: Int64?
        var listAppsCalled = false
        var wasApprovalRequested = false
        var userInputRequestedDuringTurn: Bool
        var firstGetAppStateAt: Date?
        var firstSuccessfulGetAppStateStartedAt: Date?
        var firstSuccessfulGetAppStateEndedAt: Date?
        var firstWriteAt: Date?
        var lastUpdatedAt: Date

        init(_ call: AutomationMCPMetricsToolCall) {
            turnStartedAtUnixMilliseconds = call.turnStartedAtUnixMilliseconds
            userInputRequestedDuringTurn = call.userInputRequestedDuringTurn ?? false
            lastUpdatedAt = call.receivedAt
        }

        mutating func update(_ call: AutomationMCPMetricsToolCall, at date: Date) {
            if turnStartedAtUnixMilliseconds == nil {
                turnStartedAtUnixMilliseconds = call.turnStartedAtUnixMilliseconds
            }
            wasApprovalRequested = wasApprovalRequested || call.approvalRequested
            userInputRequestedDuringTurn = userInputRequestedDuringTurn || (call.userInputRequestedDuringTurn ?? false)
            if date > lastUpdatedAt { lastUpdatedAt = date }
        }
    }

    private let emit: @Sendable (AutomationMCPMetricEmission) -> Void
    private var turnStates: [TurnKey: TurnState] = [:]

    init(emit: @escaping @Sendable (AutomationMCPMetricEmission) -> Void) {
        self.emit = emit
    }

    private func key(_ call: AutomationMCPMetricsToolCall) -> TurnKey? {
        guard let turnID = call.agentTurnID, !turnID.isEmpty else { return nil }
        return .init(sessionID: call.agentSessionID, turnID: turnID)
    }

    func record(_ call: AutomationMCPMetricsToolCall) {
        // Pruning also occurs for a call without usable turn metadata. Future
        // timestamps survive, because the comparison uses a signed Date interval.
        turnStates = turnStates.filter {
            call.receivedAt.timeIntervalSince($0.value.lastUpdatedAt) <= 1_800
        }
        guard let key = key(call) else { return }
        var state = turnStates[key] ?? TurnState(call)
        state.update(call, at: call.receivedAt)
        switch call.toolName {
        case .listApps:
            state.listAppsCalled = true
        case .getAppState:
            if state.firstGetAppStateAt == nil {
                state.firstGetAppStateAt = call.receivedAt
                if let duration = AutomationMCPMetricDuration.sinceTurnStart(call.receivedAt,
                    unixMilliseconds: state.turnStartedAtUnixMilliseconds) {
                    emit(metric(.timeToFirstGetAppState, duration, call, state,
                        approvalRequested: state.wasApprovalRequested))
                }
            }
        default:
            if state.firstWriteAt == nil {
                state.firstWriteAt = call.receivedAt
                if let duration = AutomationMCPMetricDuration.sinceTurnStart(call.receivedAt,
                    unixMilliseconds: state.turnStartedAtUnixMilliseconds) {
                    emit(metric(.timeToFirstWrite, duration, call, state,
                        approvalRequested: state.wasApprovalRequested))
                }
                if let end = state.firstSuccessfulGetAppStateEndedAt,
                   let durationFromEnd = AutomationMCPMetricDuration.between(end, and: call.receivedAt) {
                    if let start = state.firstSuccessfulGetAppStateStartedAt,
                       let durationFromStart = AutomationMCPMetricDuration.between(start, and: call.receivedAt) {
                        emit(metric(.timeFromStartOfFirstSuccessfulGetAppStateToFirstWrite,
                            durationFromStart, call, state, approvalRequested: call.approvalRequested))
                    }
                    emit(metric(.timeFromEndOfFirstSuccessfulGetAppStateToFirstWrite,
                        durationFromEnd, call, state, approvalRequested: call.approvalRequested))
                }
            }
        }
        turnStates[key] = state
    }

    func recordSuccessfulGetAppState(_ call: AutomationMCPMetricsToolCall, endedAt: Date) {
        guard call.toolName == .getAppState, let key = key(call) else { return }
        // Success does not prune or backfill metrics for a previous write.
        var state = turnStates[key] ?? TurnState(call)
        state.update(call, at: endedAt)
        if state.firstSuccessfulGetAppStateEndedAt == nil {
            state.firstSuccessfulGetAppStateStartedAt = call.receivedAt
            state.firstSuccessfulGetAppStateEndedAt = endedAt
        }
        turnStates[key] = state
    }

    private func metric(_ name: AutomationMCPMetricName, _ duration: Int,
        _ call: AutomationMCPMetricsToolCall, _ state: TurnState,
        approvalRequested: Bool) -> AutomationMCPMetricEmission {
        .init(metricName: name, durationMilliseconds: duration,
            bundleIdentifier: call.bundleIdentifier,
            toolName: call.toolName == .listApps || call.toolName == .getAppState ? nil : call.toolName,
            listAppsCalled: state.listAppsCalled, approvalRequested: approvalRequested,
            userInputRequestedDuringTurn: state.userInputRequestedDuringTurn)
    }
}
