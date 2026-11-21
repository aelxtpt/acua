import Foundation
import ApplicationServices

@MainActor struct EventStreamNativeTreeCollectionBackend:EventStreamTreeCollectionBackend {
    typealias Element=EventStreamAXNode
    typealias Identity=EventStreamSnapshotAXIdentity
    let snapshots:EventStreamNativeSnapshots
    init(snapshots:EventStreamNativeSnapshots? = nil) {self.snapshots=snapshots ?? .init()}
    func identity(_ element:Element) -> Identity {.init(element:element.element)}
    func construct(_ source:Element,context:EventStreamNodeContext) -> EventStreamTransformedNode<Element> {
        // Construction collects a fresh cache under the active
        // TaskLocal transaction; child selection uses the receiver's cache.
        EventStreamNativeNode.construct(snapshots.node(source.element),context:context)
    }
    func children(_ source:Element,context:EventStreamNodeContext) -> EventStreamChildArray<Element>? {
        EventStreamChildren(backend:EventStreamNativeChildren(parent:source)).collect(
            threshold:100,contextKind:context.kind,isWebShaped:context.isWebShaped,clippingFrame:context.windowFrame)
    }
}

@MainActor enum EventStreamNativeTreeCollection {
    // Returns the pre-transformation collection stage. Complete
    // extraction must still apply Mac/shared transforms and assign revision IDs.
    static func collect(_ source:EventStreamAXNode,context:EventStreamNodeContext = .init(),
                        filter:(Int,EventStreamAXNode)->Bool = {_,_ in true}) -> EventStreamCollectedTree<EventStreamAXNode> {
        EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend()).collect(source,context:context,filter:filter)
    }
}
