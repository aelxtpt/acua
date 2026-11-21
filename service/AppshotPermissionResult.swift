import Foundation

extension ServicePermissionResult {
    func appshotPermissionState() throws -> AppCaptureWire.PermissionState? {
        switch self {
        case .granted: return nil
        case .pending: throw ServiceError(.permissionsPending, "Computer Use permissions are still pending")
        case .denied: throw ServiceError(.permissionsNotGranted, "Computer Use permissions are not granted")
        case .appshotPermissionsAbandoned(.none): return .some(.none)
        case .appshotPermissionsAbandoned(.accessibility): return .some(.accessibility)
        case .appshotPermissionsAbandoned(.screenRecording): return .some(.screenRecording)
        case .appshotPermissionsAbandoned(.both): return .some(.both)
        }
    }
}
