import Foundation

struct EventStreamAXCaptureMetadata {
    let app:EventStreamApp
    let window:EventStreamWindow
}

@MainActor private final class EventStreamAXCaptureMetadataStorage {
    private var value:EventStreamAXCaptureMetadata?
    private var read:(()->EventStreamAXCaptureMetadata)?
    init(value:EventStreamAXCaptureMetadata) {self.value=value}
    init(read:@escaping ()->EventStreamAXCaptureMetadata) {self.read=read}
    func resolve()->EventStreamAXCaptureMetadata {
        if let value {return value}
        let result=read!();value=result;read=nil;return result
    }
}

struct EventStreamAXTreeCapture<Revision> {
    let revision:Revision
    let windowID:UInt32
    private let metadata:EventStreamAXCaptureMetadataStorage
    @MainActor init(revision:Revision,windowID:UInt32,app:EventStreamApp,window:EventStreamWindow) {
        self.revision=revision;self.windowID=windowID;metadata = .init(value:.init(app:app,window:window))
    }
    @MainActor init(revision:Revision,windowID:UInt32,metadata:@escaping ()->EventStreamAXCaptureMetadata) {
        self.revision=revision;self.windowID=windowID;self.metadata = .init(read:metadata)
    }
    @MainActor var app:EventStreamApp {metadata.resolve().app}
    @MainActor var window:EventStreamWindow {metadata.resolve().window}
    @MainActor func resolveMetadata()->EventStreamAXCaptureMetadata {metadata.resolve()}
}

// Revision selection/cache policy for recorded accessibility trees.
// The actual selection, transformed tree and rendering remain required native
// dependencies. This cache is independent of automation's published element IDs.
@MainActor
final class EventStreamAXCapture<Context, Revision> {
    private let resolveContext: (EventStreamEventTarget?) throws -> Context
    private let contextWindowID: (Context) -> UInt32
    private let captureTree: (Context, Revision?) async throws -> EventStreamAXTreeCapture<Revision>
    private let render: (EventStreamAXTreeCapture<Revision>, EventStreamAXTree.Mode, Bool, Bool) -> String
    private var previousRevision: Revision?
    private(set) var previousWindowID: UInt32?

    init(resolveContext: @escaping (EventStreamEventTarget?) throws -> Context,
         contextWindowID: @escaping (Context) -> UInt32,
         captureTree: @escaping (Context, Revision?) async throws -> EventStreamAXTreeCapture<Revision>,
         render: @escaping (EventStreamAXTreeCapture<Revision>, EventStreamAXTree.Mode, Bool, Bool) -> String) {
        self.resolveContext = resolveContext
        self.contextWindowID = contextWindowID
        self.captureTree = captureTree
        self.render = render
    }

    func capture(_ target: EventStreamEventTarget?, preferDiff: Bool) async throws -> EventStreamAXCaptureResult {
        let context = try resolveContext(target)
        let previous = preferDiff && previousWindowID == contextWindowID(context) ? previousRevision : nil
        let snapshot = try await captureTree(context, previous)
        let mode: EventStreamAXTree.Mode = previous != nil && preferDiff ? .diffFromPrevious : .fullTree
        // Render withoutRemovalSubtree and ignore the difference-line
        // budget. A backend may render a full fallback while mode remains diff.
        let text = render(snapshot, mode, true, true)
        previousRevision = snapshot.revision
        previousWindowID = snapshot.windowID
        // The recorder assembles live metadata after rendering and
        // committing the predecessor. The deferred source runs exactly once.
        let metadata=snapshot.resolveMetadata()
        return .init(ax: .init(mode: mode, text: text), app: metadata.app, window: metadata.window)
    }

    func reset() {
        previousRevision = nil
        previousWindowID = nil
    }

    // Stop clears only this field. The predecessor is released by
    // the next start/reset, not by stop itself.
    func clearPreviousWindowID() {previousWindowID=nil}
    func clearPreviousRevision() {previousRevision=nil}
}
