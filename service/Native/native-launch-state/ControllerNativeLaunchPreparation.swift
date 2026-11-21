import AppKit
import Foundation

@MainActor struct ControllerNativeApplicationOpener {
    typealias Completion = @Sendable (NSRunningApplication?, Error?) -> Void
    let openURL: (URL, NSWorkspace.OpenConfiguration, @escaping Completion) -> Void
    static var native: Self {
        .init(openURL: { NSWorkspace.shared.open($0, configuration: $1, completionHandler: $2) })
    }
    func open(_ target: ComputerUseApplicationTarget) async throws -> ControllerOwnerRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        return try await withCheckedThrowingContinuation { continuation in
            openURL(target.url, configuration) { application, error in
                // An error takes precedence over an application. The
                // impossible nil/nil reply traps.
                if let error { continuation.resume(throwing: error) }
                else {
                    guard let application else { preconditionFailure("Workspace returned neither application nor error") }
                    continuation.resume(returning: .init(application: application))
                }
            }
        }
    }
}

@MainActor struct ControllerNativeLaunchEnvironment {
    let running: (ComputerUseApplicationTarget) -> ControllerOwnerRunningApplication?
    let node: (ControllerOwnerRunningApplication) -> ControllerNativeElementContext.Node
    let opener: ControllerNativeApplicationOpener
    let now: () -> Date
    let sleep: (Duration) async throws -> Void
    let settle: (ControllerNativeElementContext.Node, Double?, Double, Bool) async throws -> ControllerNativeAppSnapshotCache?
    static func native(resources: ControllerNativeResources) -> Self {
        .init(running: { target in
            NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier).first {
                $0.bundleURL.map { ComputerUseApplicationTarget.identifier(for: $0) == target.identifier } ?? false
            }.map { .init(application: $0) }
        }, node: { resources.context.application(RunningApplicationPID.resolve($0.application)) }, opener: .native,
            now: { Date.now }, sleep: { duration in
                let clock = ContinuousClock()
                try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
            }, settle: ControllerNativeClickRuntime.native(resources: resources).settle)
    }
}

@MainActor struct ControllerNativeLaunchBackend: ControllerLaunchPreparationBackend {
    typealias Target = ComputerUseApplicationTarget
    typealias Application = ControllerOwnerRunningApplication
    typealias Node = ControllerNativeElementContext.Node
    let resources: ControllerNativeResources
    let environment: ControllerNativeLaunchEnvironment
    func running(_ target: Target) -> Application? { environment.running(target) }
    func node(_ application: Application) -> Node { environment.node(application) }
    func primaryWindow(_ application: Node) -> Node? { resources.context.context.primaryWindow(application) }
    func minimized(_ window: Node) -> Bool? { resources.geometry.value("AXMinimized", on: window) }
    func open(_ target: Target) async throws -> Application { try await environment.opener.open(target) }
    func now() -> Date { environment.now() }
    func sleep(_ interval: Duration) async throws { try await environment.sleep(interval) }
    func settle(_ application: Node, delay: Double, notificationDelay: Double, scroll: Bool) async throws {
        _ = try await environment.settle(application, delay, notificationDelay, scroll)
    }
}
