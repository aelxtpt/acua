import Foundation

/// Only capture-start supplies an abandonment ID. Late bodies remain
/// undecoded until this hook permits the handler to run.
struct ServiceRequestPermissionGate {
    let ensure: (ServicePermissionSource, String?) throws -> ServicePermissionResult
    func check(_ contract: ServiceRequestContract, capturePermissionID: () throws -> String?) throws -> ServicePermissionGrantState? {
        guard contract.requiresSystemPermissions else { return nil }
        let requestID = contract.isCaptureStart ? try capturePermissionID() : nil
        switch try ensure(contract.permissionSource, requestID) {
        case .granted: return nil
        case .pending: throw ServiceError(.permissionsPending, "Computer Use permissions are still pending")
        case .denied: throw ServiceError(.permissionsNotGranted, "Computer Use permissions are not granted")
        case .appshotPermissionsAbandoned(let state): return .some(state)
        }
    }
}
