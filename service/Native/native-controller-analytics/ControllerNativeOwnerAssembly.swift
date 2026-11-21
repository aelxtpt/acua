import AppKit
import ApplicationServices
import Foundation
import os

/// Image/tree ownership types belong to their capture pipeline. All native
/// identity, AX observation, geometry, ordering, focus and lifetime bindings are
/// concrete here, shared by the owners produced by one runtime assembly.
struct ControllerNativeOwnerAssembly<ImageFile: Hashable & Sendable, Cursor: Sendable, Tree: Sendable>: Sendable {
    typealias Node = ControllerNativeElementContext.Node
    typealias Owner = ComputerUseNativeControllerOwner<ControllerOwnerRunningApplication, Node,
        ControllerFocusNativeBindings.Focus, ControllerAXEnablementAssertion, ImageFile, Cursor, Tree>
    typealias Ordering = ControllerWindowOrdering<ControllerOwnerRunningApplication, Node>
    let resources: ControllerNativeResources
    let producer: ControllerWindowNativeProducer
    let attention: ControllerNativeAttention?
    let analytics: @Sendable (Owner.Analytics) -> Void
    let orderingLog: @Sendable (Ordering.Log) -> Void
    let hideCursor: @MainActor @Sendable (Cursor) async -> Void

    func ordering(_ ids: [UInt32]) -> Ordering {
        typealias Sources = ControllerWindowOrderingEventSources<ControllerOwnerRunningApplication, Node>
        let context = resources.context, geometry = resources.geometry
        return .init(observedWindowIDs: ids, environment: .init(
            events: { Sources.events(windowIDs: $0, buffer: $1, producer: producer) },
            frontmostApplication: { NSWorkspace.shared.frontmostApplication.map { .init(application: $0) } },
            processIdentifier: { $0.application.processIdentifier }, resolvePID: { RunningApplicationPID.resolve($0.application) },
            focusedWindow: { context.context.focusedWindow(context.application($0)) },
            windowID: { try context.identity.windowID($0.element) },
            windowOwner: { ControllerWindowDescription.lookup($0)?.ownerPID },
            onScreenWindowIDs: { ControllerOnScreenWindowIDs.read() },
            observeWorkspaceAddition: { Sources.workspace(windowIDs: $0, producer: producer, added: $1) },
            raise: { try geometry.raise($0) }, sleep: { try await ContinuousClock().sleep(for: $0) }, log: orderingLog))
    }
    var environment: Owner.Environment { environment(analytics:analytics) }
    private func environment(analytics:@escaping @Sendable (Owner.Analytics)->Void) -> Owner.Environment {
        let context = resources.context
        return .init(resolveIdentity: { try ControllerOwnerNativeBindings.identity($0) },
            makeApplicationNode: { context.application($0) }, makeOrdering: { ordering($0) },
            makeSignposter: { OSSignposter(subsystem: "local.cua", category: "ComputerUseAppController") },
            primaryWindow: { context.context.primaryWindow($0) }, children: { context.context.children($0) },
            role: { context.context.role($0) }, windowID: { try context.identity.windowID($0.element) },
            menuWindowID: { node in
                try ControllerMenuWindowID.read(node, environment: .init(
                    actualPID: { try context.identity.actualPID($0.element) },
                    rawWindowID: { try context.identity.windowID($0.element) }, windows: ControllerMenuWindowID.windows))
            }, actualPID: { try context.identity.actualPID($0.element) }, sameElement: { $0.element == $1.element },
            clearApplicationAttention: { node in
                if let pid = try? ControllerAXEnablementNative.pid(node.element, lookup: { resources.io.lookup($0)?.ordinaryPID }) {
                    attention?.clear(pid)
                }
            }, observeTermination: { ControllerWorkspaceTermination.workspace($0) },
            terminatedPID: { ControllerWorkspaceTermination.processIdentifier($0) },
            observeAX: { try context.observe(pid: $0, application: $1, handler: $2) },
            registerWeakOwner: { ControllerOwnerWeakRegistry.shared.add($0) }, notificationCenter: .default, analytics: analytics,
            acquireAccessibility: { node in
                resources.enablement.acquire(application: node, window: context.context.primaryWindow(node), context: 0)
            }, releaseAccessibility: { $0.disable() }, makeFocusEnforcer: { resources.makeFocus($0) },
            deactivateFocusEnforcer: { try? $0.deactivateFocusEnforcer() },
            setFocusEnforcerPID: { $0.startSuppressingMenuDismissalEvents(menuPID: $1) },
            clearFocusEnforcerPID: { $0.stopSuppressingMenuDismissalEvents() },
            scheduleOnMainActor: { operation in Task { @MainActor in await operation() } },
            orderOutCursor: hideCursor, now: { Date() }, sleep: { Thread.sleep(forTimeInterval: $0) })
    }
    @MainActor func makeOwner(target: ComputerUseApplicationTarget, chatID: String?, mcpRuntime: UInt8,
                              isAXTreeDiffingEnabled: Bool) throws -> Owner {
        try .init(target: target, chatID: chatID, mcpRuntime: mcpRuntime,
            isAXTreeDiffingEnabled: isAXTreeDiffingEnabled, environment: environment)
    }
}
