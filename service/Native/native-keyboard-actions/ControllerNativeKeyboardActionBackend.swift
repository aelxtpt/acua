import Foundation

@MainActor struct ControllerNativeKeyboardActionRuntime {
    typealias Event = ControllerFocusNativeEvent
    let type: @Sendable (String) async throws -> [Event]
    let press: @Sendable (String) async throws -> [Event]
    let holding: @Sendable (String) async throws -> ControllerKeyboardHeldEvents<Event>
    let send: @Sendable ([Event], Int32, Duration?) async throws -> Void
    let wait: @Sendable (Duration) async throws -> Void
    let settle: @MainActor (ControllerNativeElementContext.Node) async throws -> ControllerNativeAppSnapshotCache?
    static func native(resources: ControllerNativeResources) -> Self {
        let settling = ControllerNativeClickRuntime.native(resources: resources)
        return .init(type: { try await ControllerNativeKeyboardTyping.make($0) },
            press: { try await ControllerNativeKeyboardEvents.make(ControllerKeyboardStrokeParsing.parse($0)) },
            holding: { try await ControllerNativeKeyboardEvents.makeHolding(ControllerKeyboardStrokeParsing.parse($0)) },
            send: { try await ControllerNativeKeyboardEvents.send($0, to: $1, delay: $2) },
            wait: { try await ContinuousClock().sleep(for: $0) },
            settle: { try await settling.settle($0, 0.1, 0.25, false) })
    }
}

@MainActor struct ControllerNativeKeyboardActionBackend: ControllerKeyboardActionBackend {
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Target = ControllerKeyboardTarget<ControllerNativeElementContext.Node>
    typealias Event = ControllerFocusNativeEvent
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let runtime: ControllerNativeKeyboardActionRuntime
    func ensureFocusEnforcer() { _ = controller.owner.activateFocusEnforcer() }
    var believesFocused: Bool? { controller.owner.focusEnforcer?.state.believesFocused }
    var lastTree: Tree? { controller.owner.lastAXTree }
    func captureForFocus() async throws -> Tree {
        _ = try await controller.updateAppSnapshot(treeCache: nil, disableAXDiffing: false, skipScreenshot: false)
        guard let tree = controller.owner.lastAXTree else { throw ControllerInteractionPreparationFailure.missingAppSnapshotTree }
        return tree
    }
    func enforceFocus(in tree: Tree) async throws {
        let window = ControllerNativeAppSnapshotContext.contextual(tree.selection.value.applicationWindow.window)
        try await controller.owner.focusEnforcer?.safelyEnforceActiveState(for: window)
    }
    func keyboardTarget() throws -> Target {
        try ControllerKeyboardTargeting(backend: ControllerNativeKeyboardTarget(resources: controller.resources)).target(controller.owner.app)
    }
    var typingDelay: Duration {
        controller.owner.bundleIdentifier == "com.apple.ScreenContinuity" ? .milliseconds(5) : .microseconds(250)
    }
    func typeEvents(_ text: String) async throws -> [Event] { try await runtime.type(text) }
    func pressEvents(_ text: String) async throws -> [Event] { try await runtime.press(text) }
    func holdEvents(_ text: String) async throws -> ControllerKeyboardHeldEvents<Event> { try await runtime.holding(text) }
    func send(_ events: [Event], to target: Target, delay: Duration?) async throws { try await runtime.send(events, target.pid, delay) }
    func hold(for duration: Duration) async throws { try await runtime.wait(duration) }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle() async throws -> Cache? { try await runtime.settle(controller.owner.app) }
    func capture(cache: Cache?) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache: cache, disableAXDiffing: false, skipScreenshot: false)
    }
}
extension ControllerNativeAppController {
    func performKeyboardAction(_ parameters: ControllerKeyboardActionParameters,
                               runtime: ControllerNativeKeyboardActionRuntime? = nil) async throws -> AppSnapshot? {
        try await ControllerKeyboardOperation(backend: ControllerNativeKeyboardActionBackend(controller: self,
            runtime: runtime ?? .native(resources: resources))).perform(parameters)
    }
}
