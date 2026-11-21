import Foundation

@MainActor final class PermissionWindowServiceAdapter: ServiceSystemPermissionPresenter {
    let coordinator: PermissionWindowCoordinator<ServicePermissionRequirement>
    init(coordinator: PermissionWindowCoordinator<ServicePermissionRequirement>) { self.coordinator = coordinator }
    static func windowSource(_ source: ServicePermissionSource) -> PermissionWindowSource {
        switch source {
        case .computerUse: .computerUse
        case .appshot: .appshot
        case .timeline: .timeline
        }
    }
    static func requestOutcome(_ outcome: PermissionWindowRequestOutcome) -> ServicePermissionRequestOutcome {
        switch outcome {
        case .granted: .granted
        case .denied: .denied
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
    func present(requirements: Set<ServicePermissionRequirement>, source: ServicePermissionSource,
                 treatDismissalAsAbandonment: Bool) async -> ServicePermissionPresentationResult {
        switch await coordinator.present(requirements: requirements, source: Self.windowSource(source),
                                         treatDismissalAsAbandonment: treatDismissalAsAbandonment) {
        case .granted: .granted
        case .denied: .denied
        case .pending: .pending
        }
    }
}
