import AppKit
import SwiftUI

/// Live Appshots composition of the permission catalogue, window lifecycle,
/// row registry and System Settings requester. Other service sources still
/// need the shared service-permission owner; they do not silently route here.
@MainActor final class AppshotPermissionWindow {
    typealias Binding = SettingsAccessoryNativeBinding<NSImage>
    typealias Provider = NativeSystemSettingsPrivacyPermission<SystemSettingsNativeApplication>
    typealias Coordinator = PermissionWindowCoordinator<PermissionRequirement>
    private typealias Requester = PermissionSettingsRequester<PermissionRequirement, SystemSettingsNativeApplication, SettingsAccessoryCapture<NSImage>>
    @MainActor private final class Callbacks {
        var request: (@MainActor (PermissionRequirement) -> Void)?
        var reopen: (@MainActor (PermissionRequirement) -> Void)?
        var closed: (@MainActor () -> Void)?
        var refresh: (@MainActor () -> Void)?
    }
    let catalog: PermissionCatalog
    let viewState: PermissionWindowViewState
    let registry: PermissionRowRegistry<PermissionRequirement, NSView, NSImage>
    let host: PermissionWindowNativeHost
    let coordinator: Coordinator
    private let binding: Binding
    private let provider: Provider
    private let requester: Requester
    private let callbacks: Callbacks
    private var reopenTasks = [UUID: Task<Void, Never>]()

    init(binding: Binding,
         status: @escaping @MainActor @Sendable (PermissionRequirement) -> PermissionWindowStatus,
         onRequestFinished: @escaping @MainActor @Sendable (PermissionRequirement, PermissionWindowRequestOutcome) -> Void,
         onClose: @escaping @MainActor () -> Void) {
        let catalog = PermissionCatalog.service(source: .appshot)
        let viewState = PermissionWindowViewState()
        let registry = PermissionRowRegistry<PermissionRequirement, NSView, NSImage>(environment: .native)
        let callbacks = Callbacks()
        let content = PermissionWindowContent(state: viewState, catalog: catalog, registry: registry,
            onRequestPermission: { callbacks.request?($0) }, onOpenSettings: { callbacks.reopen?($0) },
            onRefresh: { callbacks.refresh?() })
        let host = PermissionWindowNativeHost.make(title: catalog.title, content: NSHostingView(rootView: content))
        let provider = Provider.native
        let coordinator = Coordinator(rows: catalog.rows.map { .init(requirement: $0.permission, isSupplemental: $0.isSupplemental) },
            // The pending timeout is 110 seconds, independently of the outer
            // 120-second IPC deadline.
            window: host, pendingTimeout: ServicePermissionWindowConfiguration.pendingTimeout, catalogSource: .appshot,
            environment: .init(status: status, changed: { viewState.value = $0 },
                requestFinished: onRequestFinished, closed: { callbacks.closed?() }))
        let requester = Requester(controller: coordinator, access: binding.access,
            environment: .init(sourceCapture: { registry.capture(for: $0) }, activateApplication: { NSApp.activate() }))
        self.catalog = catalog; self.viewState = viewState; self.registry = registry
        self.host = host; self.coordinator = coordinator; self.binding = binding
        self.provider = provider; self.requester = requester; self.callbacks = callbacks
        callbacks.request = { [weak self] in self?.request($0) }
        callbacks.reopen = { [weak self] in self?.reopen($0) }
        callbacks.closed = onClose
        callbacks.refresh = { [weak coordinator] in coordinator?.refresh() }
        host.didClose = { [weak coordinator] in coordinator?.windowWillClose() }
    }

    func present(requirements: Set<PermissionRequirement>, source: PermissionWindowSource,
                 treatDismissalAsAbandonment: Bool) async -> PermissionWindowResult {
        await coordinator.present(requirements: requirements, source: source,
            treatDismissalAsAbandonment: treatDismissalAsAbandonment)
    }

    private static func kind(for requirement: PermissionRequirement) -> Provider.Kind? {
        switch requirement {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        default: nil
        }
    }

    private func request(_ requirement: PermissionRequirement) {
        guard let kind = Self.kind(for: requirement) else { return }
        let permission = provider.permission(kind), requester = requester
        coordinator.request(requirement) { await requester.request(permission, for: requirement) }
    }

    private func reopen(_ requirement: PermissionRequirement) {
        guard let kind = Self.kind(for: requirement), let privacy = provider.permission(kind).privacy else { return }
        let id = UUID(), access = binding.access
        reopenTasks[id] = Task { @MainActor [weak self] in
            defer { self?.reopenTasks[id] = nil }
            try? await access.openSettingsAndPresentAccessoryIfNeeded(for: privacy)
        }
    }

    func refresh() { coordinator.refresh() }

    func applicationDidBecomeActive() {
        // Activity is independent of the grant task. Raising and refresh use
        // the controller's current missing/observation state, not row opacity.
        coordinator.raiseIfNeeded()
        coordinator.refresh()
    }

}
