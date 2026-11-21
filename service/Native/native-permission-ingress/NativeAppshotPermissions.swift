import AppKit

/// One native permission owner shared by the Appshots worker entry and the
/// other request sources.
@MainActor final class NativeAppshotPermissions {
    private static let shared = NativeAppshotPermissions()
    private typealias Binding = SettingsAccessoryNativeBinding<NSImage>
    private typealias Provider = NativeSystemSettingsPrivacyPermission<SystemSettingsNativeApplication>
    private lazy var binding = makeSettingsBinding()
    private lazy var service = makeService()

    static func configure() {
        _ = shared.service
    }

    nonisolated static func check(source: ServicePermissionSource, appshotRequestID: String?) throws -> ServicePermissionResult {
        try ServicePermissionRequestBridge(environment: .init(isMainThread: { Thread.isMainThread },
            wait: { try RequestRuntime.wait(for: $0, maximumSeconds: 120) },
            ensure: { source, requestID in await shared.service.ensure(source: source, appshotRequestID: requestID) }))
            .check(source: source, appshotRequestID: appshotRequestID)
    }

    nonisolated static func check(_ request: AppCaptureWire.Start) throws -> AppCaptureWire.PermissionState? {
        try NativeTargetPolicy.requireAllowed(request.app)
        guard !Thread.isMainThread else {
            throw ServiceError(.permissionsPending, "App capture permission requests require the service worker")
        }
        let pending = PendingResult<ServicePermissionResult>(discard: { _ in })
        let requestID = request.permissionRequestID
        let task = Task { @MainActor in
            do {
                // Check retained abandonment BEFORE cached readiness or
                // presentation. The outer unavailable-screen guard never opens UI.
                let service = shared.service
                if service.abandoned[requestID] == nil { try Permissions.requireUnlockedScreen() }
                let result = await service.ensure(source: .appshot, appshotRequestID: requestID)
                pending.complete(.success(result))
            } catch { pending.complete(.failure(error)) }
        }
        do {
            try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
            return try pending.take().appshotPermissionState()
        } catch {
            task.cancel(); pending.abandon(); throw error
        }
    }

    private func makeService() -> ServiceSystemPermissions {
        ServiceSystemPermissions(state: .init(accessibility: Permissions.accessibilityGranted(),
            screenRecording: Permissions.screenRecordingGranted()), environment: .init(
                makePresenter: { [unowned self] configuration in
                    AppshotPresenter(binding: binding, configuration: configuration, status: { [weak self] requirement in
                        guard let self else { return .unknown }
                        switch requirement {
                        case .accessibility: return service.state.accessibility ? .authorized : .notDetermined
                        case .screenRecording: return service.state.screenRecording ? .authorized : .notDetermined
                        default: return .unknown
                        }
                    })
                }))
    }

    private func makeSettingsBinding() -> Binding {
        Binding(isScreenRecording: { $0.identifier == Provider.Kind.screenRecording.identifier },
            preventActivation: { application in await NativeSystemSettingsActivation.prevent(application) },
            reenableActivation: { await NativeSystemSettingsActivation.reenable() },
            makeWindow: { permission, back, drop in
                let kind: AppshotPermissionSettingsVisits.Permission = permission.isScreenRecording ? .screenRecording : .accessibility
                return AppshotPermissionAccessory(permission: kind, appURL: AppshotPermissionAccessory.applicationBundleURL,
                    onBack: back, onDrop: drop).presentationWindow()
            }, makeTransition: { AppshotPermissionTransition.makeController().presentationTransition() })
    }

    @MainActor final class AppshotPresenter: ServiceSystemPermissionPresenter {
        private final class Callbacks { var closed: (@MainActor () -> Void)? }
        let window: AppshotPermissionWindow
        private let callbacks: Callbacks
        private var activityObserver: NSObjectProtocol?
        init(binding: SettingsAccessoryNativeBinding<NSImage>, configuration: ServiceSystemPermissions.PresenterConfiguration,
             status: @escaping @MainActor @Sendable (PermissionRequirement) -> PermissionWindowStatus) {
            let callbacks = Callbacks()
            self.callbacks = callbacks
            window = AppshotPermissionWindow(binding: binding,
                source: .init(rawValue: configuration.source.rawValue)!,
                status: status,
                onRequestFinished: { requirement, outcome in
                    let mapped: ServicePermissionRequirement
                    switch requirement {
                    case .accessibility: mapped = .accessibility
                    case .screenRecording: mapped = .screenRecording
                    default: return
                    }
                    configuration.onRequestFinished(mapped, PermissionWindowServiceAdapter.requestOutcome(outcome))
                }, onClose: { callbacks.closed?() })
            callbacks.closed = { [weak self] in
                guard let self else { return }
                if let activityObserver {
                    NotificationCenter.default.removeObserver(activityObserver)
                    self.activityObserver = nil
                }
                // The coordinator already cancelled the request task before
                // invoking this callback. C67 owns tracking/presentation cleanup
                // after its children settle; do not clear it synchronously here.
                configuration.onClose()
            }
            activityObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                object: NSApp, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.window.applicationDidBecomeActive() }
                }
        }
        func present(requirements: Set<ServicePermissionRequirement>, source: ServicePermissionSource,
                     treatDismissalAsAbandonment: Bool) async -> ServicePermissionPresentationResult {
            let requirements = Set(requirements.map { $0 == .accessibility ? PermissionRequirement.accessibility : .screenRecording })
            let source = PermissionWindowServiceAdapter.windowSource(source)
            let result = await window.present(requirements: requirements, source: source,
                treatDismissalAsAbandonment: treatDismissalAsAbandonment)
            return .init(rawValue: result.rawValue)!
        }
    }
}
