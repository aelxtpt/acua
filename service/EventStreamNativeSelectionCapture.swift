import Foundation

extension EventStreamNativeContext {
    // Description binding for custom capture owners. makeNativeAXCapture binds
    // ordinary native collection, transaction and deferred recorder metadata.
    func makeAXCapture(
        captureTree: @escaping (EventStreamCaptureContext<EventStreamAXNode>,EventStreamNativeTreeRevision.Revision?) async throws -> EventStreamAXTreeCapture<EventStreamNativeTreeRevision.Revision>
    )->EventStreamAXCapture<EventStreamCaptureContext<EventStreamAXNode>,EventStreamNativeTreeRevision.Revision> {
        makeAXCapture(captureTree:captureTree,render:{capture,mode,withoutRemovalSubtree,ignoreBudget in
            capture.revision.eventStreamDescription(mode == .fullTree ? .fullTree:.difference(from:.previous),
                lineOptions:withoutRemovalSubtree ? [.withoutRemovalSubtree]:[],ignoreDifferenceLineBudget:ignoreBudget)
        })
    }
}
