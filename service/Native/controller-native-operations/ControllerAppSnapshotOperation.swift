import Foundation

@MainActor protocol ControllerAppSnapshotBackend: Sendable {
    associatedtype Context: Sendable
    associatedtype Window: Sendable
    associatedtype Plan: Sendable
    associatedtype Cache: Sendable
    associatedtype Previous: Sendable
    associatedtype Selection: Sendable
    associatedtype Image: Sendable
    associatedtype Tree: Sendable
    associatedtype Attachment: Sendable
    var isTerminated: Bool { get }
    func terminatedError() -> any Error
    func focusedContext() throws -> Context
    var focusedMenuBarItem: Window? { get }
    var stageManagerEnabled: Bool { get }
    func prepareStageManager(_ context: Context) async throws
    func plan(_ context: Context, root: Window?, skipScreenshot: Bool) throws -> Plan
    func visibleCursorWindowID() -> UInt32?
    var ownerDiffingEnabled: Bool { get }
    func previousRevision() -> Previous?
    func captureSelection(_ context: Context, plan: Plan, root: Window?, cache: Cache?,
                          previous: Previous?, enableDiffing: Bool) async throws -> Selection
    func captureImage(_ context: Context, plan: Plan, cursorWindowID: UInt32?) async throws -> Image
    var classifierEnabled: Bool { get }
    func makeTree(_ selection: Selection, diffingEnabled: Bool) throws -> Tree
    func makeAttachment(_ selection: Selection, image: Image?, classifierEnabled: Bool) throws -> Attachment
    func retainImage(_ image: Image)
    func publishTree(_ tree: Tree)
    func publishWindow(_ selection: Selection)
    func notifyDidUpdate()
    func imageSize(_ image: Image) -> CGSize
    /// A context failure that clears by itself, such as a window that
    /// accessibility already reports while the WindowServer cannot match it yet.
    func isTransientContextFailure(_ error: any Error) -> Bool
    func waitBeforeContextRetry() async throws
}

extension ControllerAppSnapshotBackend {
    func isTransientContextFailure(_ error: any Error) -> Bool { false }
    func waitBeforeContextRetry() async throws {}
}

enum ControllerAppSnapshotContextRetry {
    /// Tries in all, the first one included.
    static let attempts = 5
}

@MainActor struct ControllerAppSnapshotOperation<Backend: ControllerAppSnapshotBackend> {
    struct Result: Sendable {
        let attachment: Backend.Attachment
        let imageSize: CGSize?
        let axTree: Backend.Tree
    }
    let backend: Backend

    /// No active/epoch check at the commit point.
    /// The async-let scope cancels and joins children before an error escapes.
    func capture(cache: Backend.Cache?, disableAXDiffing: Bool, skipScreenshot: Bool) async throws -> Result {
        if backend.isTerminated { throw backend.terminatedError() }
        let context = try await focusedContext()
        let root = backend.focusedMenuBarItem
        if backend.stageManagerEnabled { try await backend.prepareStageManager(context) }
        let plan = try backend.plan(context, root: root, skipScreenshot: skipScreenshot)
        let cursor = backend.visibleCursorWindowID()
        let ownerDiffing = backend.ownerDiffingEnabled
        let previous = backend.previousRevision()
        let selection: Backend.Selection
        let image: Backend.Image?
        if root != nil || skipScreenshot {
            selection = try await backend.captureSelection(context, plan: plan, root: root, cache: cache,
                previous: previous, enableDiffing: ownerDiffing && !disableAXDiffing)
            image = nil
        } else {
            async let pendingSelection = backend.captureSelection(context, plan: plan, root: root, cache: cache,
                previous: previous, enableDiffing: ownerDiffing && !disableAXDiffing)
            async let pendingImage = backend.captureImage(context, plan: plan, cursorWindowID: cursor)
            selection = try await pendingSelection
            image = try await pendingImage
        }
        let classifier = image == nil ? false : backend.classifierEnabled
        let tree = try backend.makeTree(selection, diffingEnabled: ownerDiffing)
        let attachment = try backend.makeAttachment(selection, image: image, classifierEnabled: classifier)
        if let image { backend.retainImage(image) }
        backend.publishTree(tree)
        backend.publishWindow(selection)
        backend.notifyDidUpdate()
        return .init(attachment: attachment, imageSize: image.map(backend.imageSize), axTree: tree)
    }

    /// A window that is opening, animating or changing size can fail to match
    /// a WindowServer window for a moment. The next read finds it, so the
    /// capture waits instead of failing the tool call. Other failures, and a
    /// transient one that outlasts the tries, are thrown unchanged.
    private func focusedContext() async throws -> Backend.Context {
        var attempt = 1
        while true {
            do { return try backend.focusedContext() }
            catch {
                guard attempt < ControllerAppSnapshotContextRetry.attempts,
                      backend.isTransientContextFailure(error) else { throw error }
                attempt += 1
                try await backend.waitBeforeContextRetry()
                if backend.isTerminated { throw backend.terminatedError() }
            }
        }
    }
}
