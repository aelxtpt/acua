import Foundation

enum ServicePermissionRequirement: Hashable, Sendable { case accessibility, screenRecording }
enum ServicePermissionRequestOutcome: UInt8, Sendable { case granted, denied, cancelled, failed }
enum ServicePermissionPresentationResult: UInt8, Sendable { case granted, denied, pending }

@MainActor protocol ServiceSystemPermissionPresenter: AnyObject {
    func present(requirements: Set<ServicePermissionRequirement>, source: ServicePermissionSource,
                 treatDismissalAsAbandonment: Bool) async -> ServicePermissionPresentationResult
}

/// App-delegate permission hook and its callbacks.
/// The native controller/UI and status observation are separate providers.
@MainActor final class ServiceSystemPermissions {
    struct State: Equatable {
        var accessibility = false, screenRecording = false
    }
    struct PresenterConfiguration: Sendable {
        let source: ServicePermissionSource
        let onRequestFinished: @MainActor @Sendable (ServicePermissionRequirement, ServicePermissionRequestOutcome) -> Void
        let onClose: @MainActor @Sendable () -> Void
    }
    struct Environment {
        var makePresenter: (PresenterConfiguration) -> any ServiceSystemPermissionPresenter
    }
    let environment: Environment
    private(set) var state: State
    private(set) var abandoned = [String: ServicePermissionGrantState]()
    private(set) var appshotRequestIDs = Set<String>()
    private var presenter: (any ServiceSystemPermissionPresenter)?
    var hasPresenter: Bool { presenter != nil }

    init(state: State = .init(), environment: Environment) { self.state = state; self.environment = environment }
    static func requiredPermissions(for source: ServicePermissionSource) -> Set<ServicePermissionRequirement> {
        source == .timeline ? [.accessibility] : [.accessibility, .screenRecording]
    }
    func updatePermission(_ requirement: ServicePermissionRequirement, outcome: ServicePermissionRequestOutcome) {
        guard outcome == .granted || outcome == .denied else { return }
        switch requirement {
        case .accessibility: state.accessibility = outcome == .granted
        case .screenRecording: state.screenRecording = outcome == .granted
        }
    }
    private var grantState: ServicePermissionGrantState {
        .init(rawValue: (state.accessibility ? 1 : 0) | (state.screenRecording ? 2 : 0))!
    }
    func ensure(source: ServicePermissionSource, appshotRequestID: String?) async -> ServicePermissionResult {
        if source == .appshot, let appshotRequestID, let cached = abandoned[appshotRequestID] {
            return .appshotPermissionsAbandoned(cached)
        }
        let required = Self.requiredPermissions(for: source)
        if state.accessibility && (source == .timeline || state.screenRecording) { return .granted }
        if source == .appshot, let appshotRequestID { appshotRequestIDs.insert(appshotRequestID) }
        let current: any ServiceSystemPermissionPresenter
        if let presenter { current = presenter }
        else {
            let configuration = PresenterConfiguration(source: source,
                onRequestFinished: { [weak self] in self?.updatePermission($0, outcome: $1) },
                onClose: { [weak self] in self?.presenterClosed() })
            current = environment.makePresenter(configuration)
            presenter = current
        }
        let result = await current.present(requirements: required, source: source, treatDismissalAsAbandonment: appshotRequestID != nil)
        return .resolve(presentation: result, source: source, appshotRequestID: appshotRequestID,
                        cached: { abandoned[$0] }, currentGrantState: { grantState })
    }
    private func presenterClosed() {
        if !state.accessibility || !state.screenRecording {
            let state = grantState
            for id in appshotRequestIDs { abandoned[id] = state }
        }
        appshotRequestIDs.removeAll()
        // The close callback has no identity/generation check.
        presenter = nil
    }
}
