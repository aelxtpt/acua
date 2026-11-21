import Foundation

/// Value-level server error and lock access families, before they are turned
/// into an ordinal and raw description.
enum ControllerNativeServerError:Error,Sendable,CustomStringConvertible {
    enum PlanReason:String,Sendable {case missing,expired,alreadyConsumed="already_consumed"}
    case senderProcessNotAuthenticated
    case couldNotGetRequestData
    case couldNotGetRequestTypeName
    case permissionsNotGranted
    case incompatibleClientVersion
    case permissionsPending
    case couldNotGetSenderPID
    case couldNotGetBootstrapPort
    case screenLocked
    case agentTurnAlreadyEnded
    case messagesPermissionsPending
    case messagesPermissionsDenied
    case messagesQueryTimedOut
    case messagesSendOutcomeUncertain
    case calendarPermissionsPending
    case calendarPermissionsDenied
    case couldNotResolveRequestType(String)
    case unknown(String)
    case messagesInvalidRequest(String)
    case messagesAmbiguousDestination(String)
    case calendarInvalidRequest(String)
    case unhandledEvent(UInt32,UInt32)
    case messagesSendPlanUnavailable(PlanReason)
    case messagesSendRateLimited(Int64)
    var ordinal:Int32 {
        switch self {
        case .senderProcessNotAuthenticated:return 0
        case .couldNotGetRequestData:return 1
        case .couldNotGetRequestTypeName:return 2
        case .permissionsNotGranted:return 9
        case .incompatibleClientVersion:return 13
        case .permissionsPending:return 14
        case .couldNotGetSenderPID:return 17
        case .couldNotGetBootstrapPort:return 19
        case .screenLocked:return 20
        case .agentTurnAlreadyEnded:return 21
        case .messagesPermissionsPending:return 22
        case .messagesPermissionsDenied:return 23
        case .messagesQueryTimedOut:return 24
        case .messagesSendOutcomeUncertain:return 28
        case .calendarPermissionsPending:return 30
        case .calendarPermissionsDenied:return 31
        case .couldNotResolveRequestType:return 3
        case .unknown:return 5
        case .messagesInvalidRequest:return 25
        case .messagesAmbiguousDestination:return 26
        case .calendarInvalidRequest:return 32
        case .unhandledEvent:return 4
        case .messagesSendPlanUnavailable:return 27
        case .messagesSendRateLimited:return 29
        }
    }
    var code:Int32 {-10000-ordinal}
    var description:String {
        switch self {
        case .senderProcessNotAuthenticated:return "Sender process is not authenticated"
        case .couldNotGetRequestData:return "Could not get request data"
        case .couldNotGetRequestTypeName:return "Could not get request type name from Apple event"
        case .permissionsNotGranted:return "Computer Use permissions are not granted"
        case .incompatibleClientVersion:return "The Computer Use server and client have a version mismatch. To use Computer Use, ask the user to relaunch their agent app so that the client will be updated to the latest version."
        case .permissionsPending:return "Computer Use permissions are still pending"
        case .couldNotGetSenderPID:return "Could not get sender PID from Apple event"
        case .couldNotGetBootstrapPort:return "Could not get XPC bootstrap mach port from Apple event"
        case .screenLocked:return "The Mac is locked. Unlock it before reading accessibility text."
        case .agentTurnAlreadyEnded:return "Computer Use is unavailable because the current turn ended. It will work again after the next user message."
        case .messagesPermissionsPending:return "Messages permission setup is still open"
        case .messagesPermissionsDenied:return "Required Messages permissions were not granted"
        case .messagesQueryTimedOut:return "The Messages database query exceeded its time limit"
        case .messagesSendOutcomeUncertain:return "Messages could not verify whether the send completed"
        case .calendarPermissionsPending:return "Calendar permissions are pending"
        case .calendarPermissionsDenied:return "Calendar permissions are not granted"
        case .couldNotResolveRequestType(let value):return "Could not resolve request type: "+value
        case .unhandledEvent(let event,let id):return "Unhandled event: \(event) \(id)"
        case .unknown(let value),.messagesInvalidRequest(let value),.messagesAmbiguousDestination(let value),.calendarInvalidRequest(let value):return value
        case .messagesSendPlanUnavailable(let reason):return reason.rawValue
        case .messagesSendRateLimited(let seconds):return "Messages sending is temporarily rate limited. Try again in \(seconds) seconds."
        }
    }
}
enum ControllerNativeLockAccessError:Error,Sendable {
    case unlockFailed,physicalInputDetected,requestHasNoThread
    var payload:String {
        switch self {
        case .unlockFailed:return "The Mac is locked and automatic unlock could not unlock it. Ask the user to unlock the Mac manually before continuing."
        case .physicalInputDetected:return "The Mac is locked and automatic unlock is paused because physical input was detected. Ask the user to unlock the Mac manually before continuing."
        case .requestHasNoThread:return "The Mac is locked and this Computer Use request cannot be associated with an agent thread. Ask the user to unlock the Mac manually before continuing."
        }
    }
}
