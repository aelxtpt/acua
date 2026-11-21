import ApplicationServices
import Foundation

enum ClientServiceErrorMapper {
    static func rethrow(_ error: NSError) throws -> Never {
        guard error.domain == "ComputerUseIPCXPC" else { throw error }
        // A service-domain NSError code that does not fit Int32 traps here.
        let code = Int32(error.code)
        let message = error.localizedDescription
        let mapped: ComputerUseIPCClient.Error
        switch code {
        case -10006: mapped = .appNotAllowed(bundleIdentifier: message)
        case -10007: mapped = .runningApplicationNotFound(bundleIdentifier: message)
        case -10008:
            if let value = Int32(message), let error = AXError(rawValue: value) { mapped = .accessibilityError(error) }
            else { mapped = .serverError(errorNumber: code, errorString: message) }
        case -10009: mapped = .permissionsNotGranted
        case -10010: mapped = .invalidApp(message)
        case -10011: mapped = .noActiveSession(app: message)
        case -10012: mapped = .userStoppedSession(app: message)
        case -10014: mapped = .permissionsPending
        case -10015: mapped = .blockedURL(url: message)
        case -10016: mapped = .userIntervened(message: message)
        case -10018: mapped = .ambiguousApp(message: message)
        case -10020: mapped = .screenLocked(message: message)
        case -10021: mapped = .turnEnded
        case -10022: mapped = .messagesPermissionsPending
        case -10023: mapped = .messagesPermissionsDenied
        case -10024: mapped = .messagesQueryTimedOut
        case -10025: mapped = .messagesInvalidRequest(message)
        case -10026: mapped = .messagesAmbiguousDestination(message)
        case -10027:
            if let reason = ComputerUseIPCMessagesSendPlanUnavailableReason(rawValue: message) { mapped = .messagesSendPlanUnavailable(reason) }
            else { mapped = .serverError(errorNumber: code, errorString: message) }
        case -10028: mapped = .messagesSendOutcomeUncertain
        case -10029: mapped = .messagesSendRateLimited(message: message)
        case -10030: mapped = .calendarPermissionsPending
        case -10031: mapped = .calendarPermissionsDenied
        case -10032: mapped = .calendarInvalidRequest(message)
        default: mapped = .serverError(errorNumber: code, errorString: message)
        }
        throw mapped
    }
}
