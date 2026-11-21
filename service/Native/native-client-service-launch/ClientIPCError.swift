import ApplicationServices
import Foundation

enum ComputerUseIPCMessagesSendPlanUnavailableReason: String, Codable, Sendable {
    case missing, expired
    case alreadyConsumed = "already_consumed"
}

extension ComputerUseIPCClient {
    enum Error: Swift.Error, CustomStringConvertible {
        case serverError(errorNumber: Int32, errorString: String)
        case invalidApp(String)
        case ambiguousApp(message: String)
        case appNotAllowed(bundleIdentifier: String)
        case runningApplicationNotFound(bundleIdentifier: String)
        case accessibilityError(AXError)
        case noActiveSession(app: String)
        case userStoppedSession(app: String)
        case blockedURL(url: String)
        case userIntervened(message: String)
        case screenLocked(message: String)
        case messagesInvalidRequest(String)
        case messagesAmbiguousDestination(String)
        case messagesSendPlanUnavailable(ComputerUseIPCMessagesSendPlanUnavailableReason)
        case messagesSendRateLimited(message: String)
        case calendarInvalidRequest(String)
        case couldNotFindServiceApp
        case permissionsNotGranted
        case permissionsPending
        case turnEnded
        case messagesPermissionsPending
        case messagesPermissionsDenied
        case messagesQueryTimedOut
        case messagesSendOutcomeUncertain
        case calendarPermissionsPending
        case calendarPermissionsDenied

        var description: String {
            switch self {
            case let .serverError(number, message): return "Computer Use server error \(number): \(message)"
            case let .invalidApp(value): return "Invalid app: \(value)"
            case let .ambiguousApp(message), let .userIntervened(message), let .screenLocked(message), let .messagesSendRateLimited(message): return message
            case let .appNotAllowed(identifier): return "Computer Use is not allowed to use the app '\(identifier)' for safety reasons."
            case let .runningApplicationNotFound(identifier): return "Running application not found: \(identifier)"
            case let .accessibilityError(error): return "Accessibility error: \(Self.accessibilityDescription(error))"
            case let .noActiveSession(app): return "Computer Use is not active for '\(app)'. You first must call `get_app_state` to get the latest state before doing other Computer Use actions. If `get_app_state` is not available in your environment, use `tool_search` to surface it."
            case .userStoppedSession: return "This application session has been explicitly stopped by the user for this turn. Stop your work and send a final message noting they stopped the session and you're ready to continue if they want you to. Computer Use can be used again in the next assistant turn."
            case .blockedURL: return "This session has been stopped because Computer Use is not allowed on the current browser URL. Stop your work and send a final message noting why the session has been ended. Note that Computer Use is not allowed on this URL even if the user navigates to it themselves."
            case let .messagesInvalidRequest(value): return "Invalid Messages request: \(value)"
            case let .messagesAmbiguousDestination(value): return "Ambiguous Messages destination: \(value)"
            case let .messagesSendPlanUnavailable(reason):
                if reason == .alreadyConsumed { return "Messages send plan was already consumed. Delivery may already have occurred." }
                return "Messages send plan is unavailable (\(reason.rawValue))."
            case let .calendarInvalidRequest(value): return "Invalid Calendar request: \(value)"
            case .couldNotFindServiceApp: return "Computer Use could not start because its runtime app is missing. Try again, and if it fails after 2 more tries, suggest that the user reinstall Aex Computer Use."
            case .permissionsNotGranted: return "Computer Use permissions are not granted"
            case .permissionsPending: return "Computer Use permissions are still pending. The user has not finished granting Accessibility and Screen Recording permissions in the Aex Computer Use window. Call this tool again, as the user is almost done finishing granting permissions. Do not end your turn yet, just call this tool again."
            case .turnEnded: return "Computer Use is unavailable because the current turn ended. It will work again after the next user message."
            case .messagesPermissionsPending: return "Messages permission setup is still open."
            case .messagesPermissionsDenied: return "Required Messages permissions were not granted."
            case .messagesQueryTimedOut: return "The Messages database query exceeded its time limit."
            case .messagesSendOutcomeUncertain: return "Messages could not verify whether the send completed. Sending again could duplicate the message."
            case .calendarPermissionsPending: return "Calendar permissions are pending"
            case .calendarPermissionsDenied: return "Calendar permissions are not granted"
            }
        }

        private static func accessibilityDescription(_ error: AXError) -> String {
            switch error.rawValue {
            case -25214: return "AXError.notEnoughPrecision"
            case -25213: return "AXError.parameterizedAttributeUnsupported"
            case -25212: return "AXError.noValue"
            case -25211: return "AXError.apiDisabled"
            case -25210: return "AXError.notificationNotRegistered"
            case -25209: return "AXError.notificationAlreadyRegistered"
            case -25208: return "AXError.notImplemented"
            case -25207: return "AXError.notificationUnsupported"
            case -25206: return "AXError.actionUnsupported"
            case -25205: return "AXError.attributeUnsupported"
            case -25204: return "AXError.cannotComplete"
            case -25203: return "AXError.invalidUIElementObserver"
            case -25202: return "AXError.invalidUIElement"
            case -25201: return "AXError.illegalArgument"
            case -25200: return "AXError.failure"
            case 0: return "AXError.success"
            default: return "(undocumented AXError)"
            }
        }
    }
}
