import Foundation
import MCP

struct AutomationMCPToolCalledTelemetry: Sendable {
    let tool: AutomationMCPTool
    let bundleIdentifier: String?
    let context: ComputerUseTelemetryContext.Snapshot
}

struct CUAMCPAutomation: Sendable {
    let listApps: @Sendable () async throws -> [ComputerUseIPCDiscoveredApp]
    let getAppState: @Sendable (ComputerUseIPCAppGetAppSnapshotRequest) async throws -> ComputerUseIPCAppSnapshotResult
    let performAction: @Sendable (ComputerUseIPCAppPerformActionRequest) async throws -> ComputerUseIPCActionResult
    let policy: AutomationMCPApproval.Policy
    let serviceDialog: AutomationMCPApproval.ServiceDialog
    let store: AppApprovalStore
    let deliveryState: AppInstructionDeliveryState
    let tracker: any AutomationMCPTurnMetricsTracking
    let approvalTelemetry: @Sendable (AutomationMCPApprovalTelemetry) -> Void
    let toolTelemetry: @Sendable (AutomationMCPToolCalledTelemetry) -> Void
    var bundle: Bundle = .main
    var now: @Sendable () -> Date = Date.init
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }

    func call(_ parameters: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
        do {
            let channel: AutomationMCPApprovalChannel = CUAMCPInvocationContext.clientSupportsElicitation
                ? .elicitation { parameters in
                    try await server.requestElicitation(message: parameters.message, mode: parameters.mode,
                        requestedSchema: parameters.requestedSchema, _meta: parameters._meta)
                }
                : .serviceDialog(serviceDialog)
            return try await call(parameters, channel: channel)
        } catch {
            // The outer MCP callback also formats errors thrown
            // before the inner authorization/execution branches (unknown names).
            return AutomationMCPErrorFormatting.result(error, span: nil)
        }
    }

    func call(_ parameters: CallTool.Parameters, channel: AutomationMCPApprovalChannel) async throws -> CallTool.Result {
        // Unknown names escape the inner handler before its two
        // error-result branches. The enclosing SDK handles that thrown error.
        guard let tool = AutomationMCPTool(rawValue: parameters.name) else {
            throw MCPToolError.unknownTool(parameters.name)
        }
        let arguments = AutomationMCPArguments(parameters.arguments)
        let authorization: AutomationMCPAuthorization?
        do {
            authorization = try await AutomationMCPApproval(store: store, policy: policy,
                channel: channel, telemetry: approvalTelemetry).authorize(tool, arguments: arguments)
        } catch {
            return AutomationMCPErrorFormatting.result(error, span: nil)
        }
        let context = ComputerUseTelemetryContext.snapshot()
        toolTelemetry(.init(tool: tool, bundleIdentifier: authorization?.bundleIdentifier, context: context))
        let call = AutomationMCPMetricsToolCall(toolName: tool, bundleIdentifier: authorization?.bundleIdentifier,
            agentSessionID: context.agentSessionID, agentTurnID: context.agentTurnID,
            turnStartedAtUnixMilliseconds: context.agentTurnStartedAtUnixMilliseconds,
            approvalRequested: authorization?.requestedApproval ?? false,
            userInputRequestedDuringTurn: context.agentUserInputRequestedDuringTurn, receivedAt: now())
        await tracker.record(call)
        // Execution metadata is attached even for list_apps, whose
        // successful authorization has no target and no confirmation flow.
        let span = AutomationMCPSpanTelemetry(targetID: authorization?.bundleIdentifier,
            didTriggerServerUserFlow: authorization?.requestedApproval ?? false)
        do {
            let result: CallTool.Result
            switch try arguments.operation(for: tool) {
            case .listApps:
                result = try await AutomationMCPFormatting.apps(listApps())
            case .getAppState(let app):
                let state = try await getAppState(.init(app: app))
                result = await AutomationMCPFormatting.state(state, deliveryState: deliveryState, bundle: bundle, read: read)
            case .performAction(let request):
                result = try await AutomationMCPFormatting.action(performAction(request), read: read)
            }
            await tracker.recordSuccessfulGetAppState(call, endedAt: now())
            return AutomationMCPSpanTelemetry.attaching(span, to: result)
        } catch {
            return AutomationMCPErrorFormatting.result(error, span: span)
        }
    }
}

extension CUAMCPAutomation {
    static func native(store: AppApprovalStore, tracker: any AutomationMCPTurnMetricsTracking,
        approvalTelemetry: @escaping @Sendable (AutomationMCPApprovalTelemetry) -> Void,
        toolTelemetry: @escaping @Sendable (AutomationMCPToolCalledTelemetry) -> Void) -> Self {
        .init(listApps: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCListAppsRequest()) },
            getAppState: { try await ComputerUseIPCClient.sendRequest($0) },
            performAction: { try await ComputerUseIPCClient.sendRequest($0) },
            policy: { try await ComputerUseIPCClient.sendRequest($0) },
            serviceDialog: { try await ComputerUseIPCClient.sendRequest($0) }, store: store,
            deliveryState: .init(), tracker: tracker, approvalTelemetry: approvalTelemetry, toolTelemetry: toolTelemetry)
    }
}
