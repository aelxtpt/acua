import Foundation
import Observation

/// Permission window state. Visibility and prominence use
/// catalogue order, while active request and animated row are separate states.
struct PermissionRowPresentation: Equatable, Sendable {
    let status: PermissionWindowStatus
    let isGranted: Bool
    let isInProgress: Bool
    let isInteractionEnabled: Bool
    let isProminent: Bool
    let buttonTitle: String
}

@MainActor @Observable final class PermissionWindowViewState {
    typealias State = PermissionWindowCoordinator<PermissionRequirement>.State
    typealias ButtonTitleProvider = @MainActor (PermissionRequirement, PermissionWindowStatus, Bool) -> String?
    var value = State()

    func visibleRows(in catalog: PermissionCatalog) -> [PermissionCatalog.Row] {
        catalog.rows.filter { $0.isSupplemental || value.requested.contains($0.permission) }
    }

    func hasMissingSupplementalPermission(in catalog: PermissionCatalog) -> Bool {
        catalog.rows.contains { $0.isSupplemental && value.statuses[$0.permission] != .authorized }
    }

    /// Skip is for remaining supplemental permissions only, after every
    ///requested permission is authorized. An empty requested set satisfies that test.
    func showsSkip(in catalog: PermissionCatalog) -> Bool {
        value.requested.allSatisfy { value.statuses[$0] == .authorized }
            && hasMissingSupplementalPermission(in: catalog)
    }

    func presentation(for row: PermissionCatalog.Row, in catalog: PermissionCatalog,
                      buttonTitleProvider: ButtonTitleProvider = { _, _, _ in nil }) -> PermissionRowPresentation {
        let status = value.statuses[row.permission] ?? .unknown
        let firstMissing = visibleRows(in: catalog).first { value.statuses[$0.permission] != .authorized }
        return .init(status: status, isGranted: status == .authorized,
            isInProgress: value.transitioningRequirement == row.permission,
            isInteractionEnabled: value.activeRequest == nil && value.transitioningRequirement == nil,
            isProminent: status != .authorized && firstMissing?.permission == row.permission,
            buttonTitle: buttonTitleProvider(row.permission, status, value.activeRequest == row.permission)
                ?? Self.defaultButtonTitle(for: row.permission, status: status))
    }

    /// Denial only changes the title for a System Settings provider.
    static func defaultButtonTitle(for requirement: PermissionRequirement, status: PermissionWindowStatus) -> String {
        guard status == .denied, let provider = requirement.provider as? PermissionProviderDescriptor else { return "Allow" }
        switch provider {
        case .accessibility, .screenRecording, .fullDiskAccess: return "Open Settings"
        default: return "Allow"
        }
    }
}
