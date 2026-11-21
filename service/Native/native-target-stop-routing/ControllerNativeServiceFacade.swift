import Foundation

enum ControllerNativeServiceFacadeError: Error { case unsupportedRoute(String) }

///A single async typed request boundary for all controller-usage operations.
///The ordinary transport must retain its authentication/preparation, encoding
///completion and error mapping when selecting this facade.
@MainActor struct ControllerNativeServiceFacade {
    let lifecycle: ControllerNativeApplicationLifecycle
    let resolver: ControllerApplicationTargetResolver
    var appSnapshotEnvironment: ControllerNativeAppSnapshotRequestEnvironment? = nil
    var actionEnvironment: ControllerNativeActionRequestEnvironment? = nil

    static func supports(_ type: String) -> Bool {
        switch DirectRequestType(rawValue:type) {
        case .appStart,.appStop,.appModify,.appGetAppSnapshot,.appPerformAction:true
        default:false
        }
    }
    func handle(type: String, body: Data, sender: SenderRequestContext?) async throws -> Data {
        let decoder = JSONDecoder(),encoder = JSONEncoder()
        switch DirectRequestType(rawValue:type) {
        case .appStart:
            let request = try decoder.decode(XPCAppUsageBody.AppIdentifier.self,from:body)
            let target = try resolver.resolve(request.app)
            return try encoder.encode(await lifecycle.start(target,requestedIdentifier:request.app,sender:sender))
        case .appStop:
            let request = try decoder.decode(XPCAppUsageBody.AppIdentifier.self,from:body)
            return try encoder.encode(await lifecycle.stop(request.app))
        case .appModify:
            let request = try decoder.decode(XPCAppUsageBody.Modify.self,from:body)
            let target = try resolver.resolve(request.app)
            return try encoder.encode(await lifecycle.modify(target,requestedIdentifier:request.app,sender:sender,
                deactivate:request.modification.key == "deactivate"))
        case .appGetAppSnapshot:
            let request = try decoder.decode(XPCAppUsageBody.AppSnapshot.self,from:body)
            let target = try resolver.resolve(request.app)
            return try encoder.encode(await lifecycle.getAppSnapshot(target,requestedIdentifier:request.app,sender:sender,
                disableAXDiffing:request.disableDiff,requestEnvironment:appSnapshotEnvironment))
        case .appPerformAction:
            let request = try decoder.decode(XPCAppUsageBody.PerformAction.self,from:body)
            let target = try resolver.resolve(request.app)
            return try encoder.encode(await lifecycle.performAction(target,requestedIdentifier:request.app,sender:sender,
                action:request.action,requestEnvironment:actionEnvironment))
        default:throw ControllerNativeServiceFacadeError.unsupportedRoute(type)
        }
    }
}
