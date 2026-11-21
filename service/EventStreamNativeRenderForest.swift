import Foundation
import ApplicationServices

@MainActor enum EventStreamNativeRenderForest {
    //0x100775884 supplies LM-readable descriptions to the generic render-tree
    // mapper. Numeric IDs, lineage/diffs and capture-factory ordering are still
    // revision/owner dependencies, rather than automation-session ID reuse.
    static func build(_ tree:EventStreamCollectedTree<EventStreamAXNode>,
                      context:inout EventStreamMacTransformationContext)
        ->EventStreamRenderedTree<EventStreamSnapshotAXIdentity> {
        EventStreamRenderForest.build(tree,context:&context,
            identity:{EventStreamSnapshotAXIdentity(element:$0.element)},
            describe:{node,current in EventStreamNativeNodeRendering.description(node,context:&current)})
    }
}
