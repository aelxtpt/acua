import Foundation

/// Maps the raw server code/payload to the client's description. Unrecognized codes and unparseable associated values preserve
///their raw payload in the generic server-error form.
enum ControllerNativeClientErrorCodec {
    static let constants:[Int32:String]=[
        -10009:"Computer Use permissions are not granted",
        -10012:"This application session has been explicitly stopped by the user for this turn. Stop your work and send a final message noting they stopped the session and you're ready to continue if they want you to. Computer Use can be used again in the next assistant turn.",
        -10014:"Computer Use permissions are still pending. The user has not finished granting Accessibility and Screen Recording permissions in the Aex Computer Use window. Call this tool again, as the user is almost done finishing granting permissions. Do not end your turn yet, just call this tool again.",
        -10015:"This session has been stopped because Computer Use is not allowed on the current browser URL. Stop your work and send a final message noting why the session has been ended. Note that Computer Use is not allowed on this URL even if the user navigates to it themselves.",
        -10021:"Computer Use is unavailable because the current turn ended. It will work again after the next user message.",
        -10022:"Messages permission setup is still open.",
        -10023:"Required Messages permissions were not granted.",
        -10024:"The Messages database query exceeded its time limit.",
        -10028:"Messages could not verify whether the send completed. Sending again could duplicate the message.",
        -10030:"Calendar permissions are pending",
        -10031:"Calendar permissions are not granted"
    ]
    static func describe(code:Int32,payload:String)->String {
        if let value=constants[code]{return value}
        switch code {
        case -10010:return "Invalid app: "+payload
        case -10018,-10016,-10020,-10029:return payload
        case -10006:return "Computer Use is not allowed to use the app '"+payload+"' for safety reasons."
        case -10007:return "Running application not found: "+payload
        case -10008:
            guard let value=Int32(payload) else{return generic(code:code,payload:payload)}
            return "Accessibility error: "+accessibilityDescription(value)
        case -10011:return "Computer Use is not active for '"+payload+"'. You first must call `get_app_state` to get the latest state before doing other Computer Use actions. If `get_app_state` is not available in your environment, use `tool_search` to surface it."
        case -10025:return "Invalid Messages request: "+payload
        case -10026:return "Ambiguous Messages destination: "+payload
        case -10027:
            switch payload {
            case "missing","expired":return "Messages send plan is unavailable ("+payload+")."
            case "already_consumed":return "Messages send plan was already consumed. Delivery may already have occurred."
            default:return generic(code:code,payload:payload)
            }
        case -10032:return "Invalid Calendar request: "+payload
        default:return generic(code:code,payload:payload)
        }
    }
    static func generic(code:Int32,payload:String)->String {"Computer Use server error \(code): "+payload}
    static func accessibilityDescription(_ status:Int32)->String {
        let names=["notEnoughPrecision","parameterizedAttributeUnsupported","noValue","apiDisabled","notificationNotRegistered","notificationAlreadyRegistered","notImplemented","notificationUnsupported","actionUnsupported","attributeUnsupported","cannotComplete","invalidUIElementObserver","invalidUIElement","illegalArgument","failure"]
        if status==0{return "AXError.success"}
        let index=Int64(status)+25214
        guard index>=0 && index<Int64(names.count) else{return "(undocumented AXError)"}
        return "AXError."+names[Int(index)]
    }
}
