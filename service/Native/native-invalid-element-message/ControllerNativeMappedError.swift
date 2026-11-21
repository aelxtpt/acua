import Foundation

/// Classification yields a code ordinal and a raw payload, which XPC stores in
/// NSError. Socket callers instead run the client mapping and stringify that error.
struct ControllerNativeMappedError: Error, Sendable {
    let code: CUErrorCode
    let payload: String
    static func classify(_ error: any Error) -> Self {
        if let mapped = error as? Self { return mapped }
        if let failure=error as? ControllerNativeServerError {
            return .init(code:CUErrorCode(rawValue:Int(failure.code))!,payload:failure.description)
        }
        if let failure=error as? ControllerNativeLockAccessError {return .init(code:.screenLocked,payload:failure.payload)}
        if let failure=error as? LockScreenAutoUnlockCoordinator.AccessError {return .init(code:.screenLocked,payload:failure.description)}
        if let failure = error as? ControllerApplicationTargetLookupError {
            switch failure {
            case .invalid(let query): return .init(code:.invalidApp,payload:query)
            case .ambiguous: return .init(code:.ambiguousApp,payload:failure.description)
            }
        }
        if let failure = error as? ControllerNativeApplicationLifecycleError {
            switch failure {case .forbiddenTarget(let id):return .init(code:.appNotAllowed,payload:id)}
        }
        if let failure = error as? ControllerInstanceResolutionError {
            switch failure {
            case .noInstance(let id):return .init(code:.noActiveSession,payload:id)
            case .stoppedByUser(let id):return .init(code:.userStoppedSession,payload:id)
            }
        }
        if let failure = error as? ControllerInterventionAdmissionError {
            switch failure {case .userIntervened(let message):return .init(code:.userIntervened,payload:message)}
        }
        if let failure = error as? ComputerUseControllerIdentityError,
           case .runningApplicationNotFound(let id) = failure {return .init(code:.runningApplicationNotFound,payload:id)}
        if let failure = error as? ControllerNativeElementDecoding.Failure,
           case .accessibility(let status) = failure {return .init(code:.accessibilityError,payload:String(status))}
        if let failure = error as? ControllerAppSnapshotRequestFailure,
           case .blockedURL(let url) = failure {return .init(code:.blockedURL,payload:url.absoluteString)}
        if let failure = error as? ControllerCoordinateTargetFailure {
            switch failure {
            case .noWindows:return .init(code:.unknownError,payload:"noWindowsAvailable")
            case .noWindowAtPoint(let point):return .init(code:.unknownError,payload:"windowNotFoundAtPosition(\((point.x,point.y)))")
            }
        }
        // The numeric missing-ID case is formatted before
        // generic server-error classification (native wire code -10005).
        if let failure = error as? ControllerElementRefetchFailure,
           case .missingID(let id) = failure {
            return .init(code:.unknownError,payload:"\(id) is an invalid element ID")
        }
        return .init(code:.unknownError,payload:String(describing:error))
    }
    var xpcError: NSError { .init(domain:"ComputerUseIPCXPC",code:code.rawValue,userInfo:[NSLocalizedDescriptionKey:payload]) }
    var socketDescription:String {ControllerNativeClientErrorCodec.describe(code:Int32(code.rawValue),payload:payload)}
    static func accessibilityDescription(_ status:Int32)->String {ControllerNativeClientErrorCodec.accessibilityDescription(status)}
}
