import Foundation
import ApplicationServices

@MainActor enum EventStreamNativeTreeTransformation {
    //0x1007653C4 ->0x10077570C ->0x100773644: recollect the target's native
    // source with an empty path and a new visited set, under the active capture
    // transaction. Edited presentation fields/loaded children are not reused.
    static func rebuild(_ children:inout [EventStreamCollectedItem<EventStreamAXNode>],
                        target:EventStreamCollectedItem<EventStreamAXNode>,
                        context:EventStreamMacTransformationContext,snapshots:EventStreamNativeSnapshots) {
        let nodeContext=EventStreamNodeContext(kind:context.type.rawValue,isCatalyst:context.isCatalyst,
            isWebShaped:context.isWebShaped,isChromium:context.isChromium,windowFrame:context.windowFrame)
        let captured=EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend(snapshots:snapshots))
            .collect(target.node.element,context:nodeContext)
        children.append(contentsOf:captured.roots)
    }
    // Ordinary native AX binding with an explicit context. The context-creating
    // entry is supplied by EventStreamNativeTransformationContext. Native node
    // descriptions are the default; focus-tree selection, render details,
    // hosted ownership and revision/producer remain separate dependencies.
    static func transform(
        _ tree:EventStreamCollectedTree<EventStreamAXNode>,using passes:[EventStreamMacTreeTransformation]=EventStreamMacTreeTransformation.defaultPipeline,
        context:inout EventStreamMacTransformationContext,
        backend:EventStreamNativeMacTransformationBackend?=nil,
        attributed:EventStreamNativeAttributedTextBackend?=nil,
        formatter:EventStreamNativeAttributedMarkdown?=nil,snapshots:EventStreamNativeSnapshots?=nil,
        render:@MainActor (EventStreamTransformedNode<EventStreamAXNode>,inout EventStreamMacTransformationContext)throws->String = EventStreamNativeNodeRendering.description
    ) throws -> EventStreamCollectedTree<EventStreamAXNode> {
        let reader=snapshots ?? EventStreamNativeSnapshots()
        let mac=backend ?? EventStreamNativeMacTransformationBackend(titles:EventStreamNativeTitleAssociationBackend(snapshots:reader))
        let acquisition=attributed ?? EventStreamNativeAttributedTextBackend(snapshots:reader)
        let writer=formatter ?? EventStreamNativeAttributedMarkdown(capture:{reader.node($0)})
        return try EventStreamTreeTransformation.transformMac(tree,using:passes,context:&context,
            backend:mac,attributed:acquisition,format:writer.format,
            rebuild:{children,target,current in rebuild(&children,target:target,context:current,snapshots:reader)},
            render:{node,current in try render(node,&current)})
    }
}
