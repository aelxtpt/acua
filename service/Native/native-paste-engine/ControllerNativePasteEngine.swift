import AppKit
import Foundation

@MainActor struct ControllerNativePasteRuntime {
    let representations: @Sendable (String, ControllerPasteFormat) async throws -> [ControllerPasteRepresentation]
    let send: @MainActor (ControllerNativeElementContext.Node) async throws -> Void
    let firstRead: @Sendable (ControllerNativePasteDataProvider, Duration) async throws -> Bool
    let settle: @MainActor (ControllerNativeElementContext.Node) async throws -> ControllerNativeAppSnapshotCache?
    /// Explicit rendering dependency prevents accidentally substituting the
    /// legacy importer for the resource-blocked rich conversions.
    static func native(resources: ControllerNativeResources, rendering: ControllerPasteRendering) -> Self {
        let keyboard = ControllerNativeKeyboardActionRuntime.native(resources:resources)
        return .init(representations:{ try await rendering.representations(text:$0,format:$1) },send:{ app in
            let target = try ControllerKeyboardTargeting(backend:ControllerNativeKeyboardTarget(resources:resources)).target(app)
            let events = try await ControllerNativeKeyboardEvents.make(ControllerKeyboardStrokeParsing.parse("super+v"))
            try await ControllerNativeKeyboardEvents.send(events,to:target.pid,delay:nil)
            withExtendedLifetime(target) {}
        },firstRead:{ provider,timeout in
            try await ControllerPasteWaiting.firstRead(timeout:timeout) {
                var iterator = provider.reads.makeAsyncIterator()
                return await iterator.next() != nil
            }
        },settle:keyboard.settle)
    }
}

@MainActor struct ControllerNativePasteEngineBackend: ControllerPasteEngineBackend {
    typealias Observation = ControllerNativePasteObservation
    typealias Transaction = ControllerPasteboardTransaction<ControllerNativePasteboardBackend>
    @MainActor final class Session {
        let transaction: Transaction
        let clipboard: Transaction.Session
        init(transaction: Transaction, clipboard: Transaction.Session) { self.transaction = transaction; self.clipboard = clipboard }
    }
    let controller: ControllerNativeAppController
    let runtime: ControllerNativePasteRuntime
    let pasteboard: NSPasteboard
    func ensureInitialFocus() throws {
        let focus = controller.owner.activateFocusEnforcer()
        //The concrete focus resource always supplies a known belief.
        try focus.enforceActiveState(for:controller.resources.context.context.primaryWindow(controller.owner.app))
    }
    func observe() throws -> Observation {
        let resources = controller.resources
        let focused = ControllerNativeKeyboardTarget(resources:resources).focusedElement(controller.owner.app)
        // Only a hosted node needs the policy bridge; the raw path keeps the
        // ordered multiple-attribute mask and tolerated AX statuses.
        let io = focused.flatMap { resources.io.lookup($0.element) == nil ? nil:resources.context.io }
        return try .init(pid:controller.owner.pid,focused:focused,io:io,logRegistrationError:resources.context.log)
    }
    func stop(_ observation: Observation) { observation.stop() }
    func transaction(_ observation: Observation) -> Transaction {
        .init(backend:observation.pasteboardBackend(pasteboard,logOwnershipLost:{
            controller.resources.context.log("pasteboard ownership lost",ControllerPasteEngineFailure.ownershipLost)
        }))
    }
    func prepare(text: String, format: ControllerPasteFormat, observation: Observation) async throws -> Session {
        let values = try await runtime.representations(text,format)
        let transaction = transaction(observation)
        do { return Session(transaction:transaction,clipboard:try transaction.prepare(values)) }
        catch ControllerPasteboardFailure.failedToProvideData { throw ControllerPasteEngineFailure.failedToProvideData }
    }
    func markDispatched(_ observation: Observation) { observation.markDispatched() }
    func enforceKeyboardFocus() async throws {
        let backend = ControllerNativeKeyboardActionBackend(controller:controller,runtime:.native(resources:controller.resources))
        backend.ensureFocusEnforcer()
        if backend.believesFocused != nil {
            let tree: ControllerRefetchableAppSnapshotTree
            if let old = backend.lastTree { tree = old } else { tree = try await backend.captureForFocus() }
            try await backend.enforceFocus(in:tree)
        }
    }
    func sendPasteShortcut() async throws { try await runtime.send(controller.owner.app) }
    func markNeedsUISettle() { controller.owner.needsUISettleBeforeAppSnapshot = true }
    func waitForRead(_ session: Session, timeout: Duration) async throws -> Bool { try await runtime.firstRead(session.clipboard.provider,timeout) }
    func checkCancellation() throws { try Task.checkCancellation() }
    func ownsGeneration(_ session: Session) -> Bool { pasteboard.changeCount == session.clipboard.generation }
    func pollAcknowledgement(_ session: Session, observation: Observation, timeout: Double, delay: Double) async throws -> Bool {
        let poll = observation.acknowledgementPoll { session.transaction.restore(session.clipboard) }
        return try await ControllerPasteWaiting.poll(timeout:timeout,delay:delay) { try await poll.poll() }
    }
    func failedToProvideData(_ session: Session) -> Bool { session.clipboard.provider.failedToProvideData }
    func restore(_ session: Session) -> Bool {
        session.transaction.restore(session.clipboard)
    }
}

@MainActor struct ControllerNativePasteBackend: ControllerPasteBackend {
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias AppSnapshot = ControllerNativeAppController.AppSnapshot
    let controller: ControllerNativeAppController
    let runtime: ControllerNativePasteRuntime
    func checkCancellation() throws { try Task.checkCancellation() }
    func globallySerializedPaste(text: String, format: ControllerPasteFormat) async throws {
        let backend = ControllerNativePasteEngineBackend(controller:controller,runtime:runtime,pasteboard:.general)
        try await ControllerGlobalPasteQueue.shared.sync {
            try await ControllerPasteEngine(backend:backend).paste(text:text,format:format)
        }
    }
    var needsUISettleBeforeAppSnapshot: Bool {
        get { controller.owner.needsUISettleBeforeAppSnapshot }
        nonmutating set { controller.owner.needsUISettleBeforeAppSnapshot = newValue }
    }
    func settle() async throws -> Cache? { try await runtime.settle(controller.owner.app) }
    func capture(cache: Cache?) async throws -> AppSnapshot {
        try await controller.updateAppSnapshot(treeCache:cache,disableAXDiffing:false,skipScreenshot:false)
    }
}

extension ControllerNativeAppController {
    func performPaste(_ parameters: ControllerPasteParameters, runtime: ControllerNativePasteRuntime) async throws -> AppSnapshot? {
        try await ControllerPasteOperation(backend:ControllerNativePasteBackend(controller:self,runtime:runtime)).paste(parameters)
    }
}
