import Foundation

struct ServiceRequestContract: Sendable {
    let typeName: String
    var preparation: RequestPreparation { .init(requestType: typeName) }
    var isTurnEnded: Bool { typeName == "ComputerUseIPCTurnEndedRequest" }
    var isCaptureStart: Bool { typeName == "ComputerUseIPCAppStartCaptureRequest" }
    var isModify: Bool { typeName == "ComputerUseIPCAppModifyRequest" }
    var decodesBeforePolicy: Bool { preparation.decodesBeforePreparation || isModify }
    var checksGlobalConfiguration: Bool {
        typeName == "ComputerUseIPCListAppsRequest" || typeName == "ComputerUseIPCStartAudioRecordingRequest"
    }
    var permissionSource: ServicePermissionSource {
        switch typeName {
        case "ComputerUseIPCAppStartCaptureRequest", "ComputerUseIPCAppNextCaptureUpdateRequest": .appshot
        case "ComputerUseIPCTimelineStartRequest", "ComputerUseIPCTimelineResumeRequest": .timeline
        default: .computerUse
        }
    }
    var requiresSystemPermissions: Bool {
        switch typeName {
        case "ComputerUseIPCAppStartRequest", "ComputerUseIPCAppModifyRequest", "ComputerUseIPCAppPerformActionRequest",
             "ComputerUseIPCStartAudioRecordingRequest", "ComputerUseIPCAppGetAppSnapshotRequest",
             "ComputerUseIPCAppStartCaptureRequest", "ComputerUseIPCAppNextCaptureUpdateRequest",
             "ComputerUseIPCEventStreamStartRequest", "ComputerUseIPCTimelineStartRequest", "ComputerUseIPCTimelineResumeRequest": true
        default: false
        }
    }
}

/// The policy layer returns its own errors. Its inputs distinguish
/// whole-app policy, activation-only policy and the global enabled flag.
enum ServiceRequestPolicyCheck<Body> {
    case application(Body)
    case configuration
}

@MainActor final class AuthenticatedRequestPipeline {
    enum Outcome<Response: Sendable>: Sendable { case handled(Response), appshotPermissionsAbandoned(ServicePermissionGrantState) }
    typealias Prepare = @MainActor (_ preparesTurn: Bool, _ allowsAutoUnlock: Bool) async throws -> Void
    typealias EnsurePermissions = @MainActor (ServicePermissionSource, String?) async -> ServicePermissionResult
    private let activity: RequestActivity
    private let prepare: Prepare?
    private let ensurePermissions: EnsurePermissions?

    init(activity: RequestActivity, prepare: Prepare?, ensurePermissions: EnsurePermissions?) {
        self.activity = activity; self.prepare = prepare; self.ensurePermissions = ensurePermissions
    }

    /// No new cancellation/deadline checks or implicit end-of-turn are inserted.
    /// The transport's task and existing provider operations retain their policy.
    func execute<Body: Sendable, Response: Sendable>(contract: ServiceRequestContract, sender: SenderRequestContext?,
        decode: () throws -> Body, modificationActivates: (Body) -> Bool = { _ in false },
        capturePermissionID: (Body) -> String? = { _ in nil },
        policy: (ServiceRequestPolicyCheck<Body>) async throws -> Void,
        policyRequest: (Body) async throws -> Response,
        handle: (Body) async throws -> Response) async throws -> Outcome<Response> {
        let early = contract.decodesBeforePolicy ? try decode() : nil
        if contract.preparation.isPolicy { return .handled(try await policyRequest(early!)) }
        if contract.preparation.isAppUsage || contract.isModify && modificationActivates(early!) {
            try await policy(.application(early!))
        }
        if contract.checksGlobalConfiguration { try await policy(.configuration) }
        let lease = activity.begin(contract.preparation)
        defer { lease?.cancel() }
        if !contract.isTurnEnded, let prepare {
            try await prepare(contract.preparation.preparesAgentTurn,
                              contract.preparation.holdsActivity && (sender?.allowsLockScreenAutoUnlock ?? false))
        }
        // Only capture-start needs its permission ID decoded before the generic
        // permission hook. Other bodies remain lazy until after that hook.
        let capture = contract.isCaptureStart ? try decode() : nil
        if contract.requiresSystemPermissions, let ensurePermissions {
            let result = await ensurePermissions(contract.permissionSource, capture.flatMap(capturePermissionID))
            switch result {
            case .granted: break
            case .pending: throw ServiceError(.permissionsPending, "Computer Use permissions are still pending")
            case .denied: throw ServiceError(.permissionsNotGranted, "Computer Use permissions are not granted")
            case .appshotPermissionsAbandoned(let state): return .appshotPermissionsAbandoned(state)
            }
        }
        let body = try early ?? capture ?? decode()
        return .handled(try await handle(body))
    }
}
