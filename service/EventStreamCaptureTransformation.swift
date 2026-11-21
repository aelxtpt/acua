import Foundation

struct EventStreamCaptureTransformedTrees<Element> {
    var main:EventStreamCollectedTree<Element>
    var focus:EventStreamCollectedTree<Element>?
}

@MainActor enum EventStreamCaptureTransformation {
    // Raw focus was extracted by the caller before these phases. Main and
    // focus share one evolving context throughout.
    static func run<Element>(
        main:EventStreamCollectedTree<Element>,focus:EventStreamCollectedTree<Element>?,
        context:inout EventStreamMacTransformationContext,
        transform:(EventStreamCollectedTree<Element>,inout EventStreamMacTransformationContext)throws->EventStreamCollectedTree<Element>,
        describe:(EventStreamTransformedNode<Element>,inout EventStreamMacTransformationContext)throws->String,
        retrim:(inout EventStreamCollectedTree<Element>,inout EventStreamMacTransformationContext)->Void
    ) rethrows -> EventStreamCaptureTransformedTrees<Element> {
        let originalConfiguration=context.urlShortener.configuration
        context.urlShortener.reset()
        var main=try transform(main,&context)
        var focus=try focus.map {try transform($0,&context)}
        for item in main.preorder {_ = try describe(item.node,&context)}
        if let focus {for item in focus.preorder {_ = try describe(item.node,&context)}}
        _ = context.urlShortener.compactConfigurationIfNeeded()
        context.urlShortener.reset()
        if context.urlShortener.configuration != originalConfiguration {
            retrim(&main,&context)
            if var focused=focus {retrim(&focused,&context);focus=focused}
        }
        return .init(main:main,focus:focus)
    }
}

@MainActor enum EventStreamNativeCaptureTransformation {
    static func run(main:EventStreamCollectedTree<EventStreamAXNode>,focus:EventStreamCollectedTree<EventStreamAXNode>?,
                    context:inout EventStreamMacTransformationContext,
                    snapshots:EventStreamNativeSnapshots?=nil)throws->EventStreamCaptureTransformedTrees<EventStreamAXNode> {
        let reader=snapshots ?? EventStreamNativeSnapshots()
        return try EventStreamCaptureTransformation.run(main:main,focus:focus,context:&context,
            transform:{tree,current in try EventStreamNativeTreeTransformation.transform(tree,context:&current,snapshots:reader)},
            describe:EventStreamNativeNodeRendering.description,retrim:EventStreamTreeURLTrimming.trim)
    }

    // The full raw source/cache/transaction/menu/focus/metadata owner remains
    // separate. This binds its transformed pair to the revision APIs.
    static func revision(_ trees:EventStreamCaptureTransformedTrees<EventStreamAXNode>,
                         previous:EventStreamNativeTreeRevision.Revision?,enableAXDiffing:Bool,
                         context:inout EventStreamMacTransformationContext)throws->EventStreamNativeTreeRevision.Revision {
        if enableAXDiffing,let previous {
            return try EventStreamNativeTreeRevision.appending(previous,tree:trees.main,focusTree:trees.focus,context:&context)
        }
        return try EventStreamNativeTreeRevision.root(trees.main,focusTree:trees.focus,context:&context)
    }
}
