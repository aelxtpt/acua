import Foundation
import MCP

enum AutomationMCPErrorFormatting {
    static func span(from error: any Error) -> AutomationMCPSpanTelemetry? {
        guard let error = error as? MCPToolError else { return nil }
        let bundle: String, requested: Bool
        switch error {
        case .appBlockedByPolicy(let value), .appNotAllowed(let value):
            bundle = value; requested = false
        case .appApprovalDenied(let value), .appApprovalDeniedInDialog(let value), .appApprovalCanceled(let value),
             .appApprovalPersistenceUnavailable(let value):
            bundle = value; requested = true
        case .missingArgument, .invalidArgument, .unknownTool: return nil
        }
        return .init(targetID: bundle, didTriggerServerUserFlow: requested)
    }

    static func result(_ error: any Error, span explicit: AutomationMCPSpanTelemetry?) -> CallTool.Result {
        let underlying: any Error
        let span: AutomationMCPSpanTelemetry?
        if let wrapped = error as? AutomationMCPErrorWithSpanTelemetry {
            underlying = wrapped.underlyingError
            span = explicit ?? wrapped.span
        } else {
            underlying = error
            span = explicit ?? Self.span(from: underlying)
        }
        let isError: Bool?
        if let ipc = underlying as? ComputerUseIPCClient.Error {
            switch ipc {
            case .noActiveSession, .userStoppedSession, .userIntervened, .screenLocked, .permissionsPending:
                isError = nil
            default: isError = true
            }
        } else { isError = true }
        return AutomationMCPSpanTelemetry.attaching(span,
            to: .init(content: [.text(String(describing: underlying))], isError: isError))
    }
}
