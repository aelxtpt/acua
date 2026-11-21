import Foundation

enum ServicePermissionSource: UInt8, Sendable { case computerUse, appshot, timeline }
enum ServicePermissionGrantState: UInt8, Sendable, CaseIterable { case none, accessibility, screenRecording, both }
enum ServicePermissionResult: Equatable, Sendable {
    case appshotPermissionsAbandoned(ServicePermissionGrantState)
    case granted, denied, pending

    static func resolve(presentation: ServicePermissionPresentationResult, source: ServicePermissionSource,
        appshotRequestID: String?, cached: (String) -> ServicePermissionGrantState?,
        currentGrantState: () -> ServicePermissionGrantState) -> Self {
        switch presentation {
        case .granted: return .granted
        case .pending: return .pending
        case .denied:
            if source == .appshot, let appshotRequestID {
                return .appshotPermissionsAbandoned(cached(appshotRequestID) ?? currentGrantState())
            }
            return .denied
        }
    }


}

enum ServicePermissionWindowConfiguration {
        static let pendingTimeout: Duration = .seconds(110)
}

