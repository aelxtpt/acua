import AppKit
import ApplicationServices
import Foundation

struct ControllerOwnerRunningApplication: @unchecked Sendable { let application: NSRunningApplication }
struct ControllerOwnerAXWindow: @unchecked Sendable { let element: AXUIElement }

enum ControllerOwnerNativeBindings {
    typealias Ordering = ControllerWindowOrdering<ControllerOwnerRunningApplication, ControllerOwnerAXWindow>
    struct RaiseFailure: Error { let status: AXError }
    @MainActor static func identity(_ target: ComputerUseApplicationTarget) throws -> (ControllerOwnerRunningApplication, Int32) {
        let identity = try ComputerUseControllerProcessIdentity<NSRunningApplication>(target: target)
        return (.init(application: identity.application), identity.pid)
    }
    static func applicationNode(_ pid: Int32) -> SettingsNativeAXElement { .init(element: AXUIElementCreateApplication(pid)) }
    static func observeAX(pid: Int32, application: SettingsNativeAXElement,
        handler: @escaping @Sendable (SettingsNativeAXElement, String) -> Void) throws -> any ControllerOwnerAXObservation<SettingsNativeAXElement> {
        try ControllerAXNotificationRegistration<ControllerAXNativeObserver, SettingsNativeAXElement>(
            pid: pid, application: application, environment: .native, handler: handler)
    }

    /// Event production is concrete. Focused-window access remains an explicit
    /// transaction-aware provider, rather than silently using the legacy getter.
    static func ordering(producer: ControllerWindowNativeProducer,
        focusedWindow: @escaping @Sendable (Int32) -> ControllerOwnerAXWindow?,
        identity: ControllerAXIdentityReader<SettingsNativeAXElement>,
        log: @escaping @Sendable (Ordering.Log) -> Void) -> Ordering {
        typealias Sources = ControllerWindowOrderingEventSources<ControllerOwnerRunningApplication, ControllerOwnerAXWindow>
        return Ordering(observedWindowIDs: [], environment: .init(
            events: { Sources.events(windowIDs: $0, buffer: $1, producer: producer) },
            frontmostApplication: { NSWorkspace.shared.frontmostApplication.map { .init(application: $0) } },
            processIdentifier: { $0.application.processIdentifier }, resolvePID: { RunningApplicationPID.resolve($0.application) },
            focusedWindow: focusedWindow,
            windowID: { try identity.windowID(.init(element: $0.element)) },
            windowOwner: { ControllerWindowDescription.lookup($0)?.ownerPID },
            onScreenWindowIDs: { ControllerOnScreenWindowIDs.read() },
            observeWorkspaceAddition: { Sources.workspace(windowIDs: $0, producer: producer, added: $1) },
            raise: { window in
                let status = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                guard status == .success || status == .cannotComplete || status == .attributeUnsupported else {
                    throw RaiseFailure(status: status)
                }
            }, sleep: { try await ContinuousClock().sleep(for: $0) }, log: log))
    }
}
