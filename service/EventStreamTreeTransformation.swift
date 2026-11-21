import Foundation

@MainActor enum EventStreamTreeTransformation {
    // Apply the complete pipeline to a parent, then transform the surviving
    // item's child tree. Replacement restarts the entire pipeline, without a
    // cycle guard.
    static func transform<Element,Pass,Context>(
        _ tree:EventStreamCollectedTree<Element>,using passes:[Pass],context:inout Context,
        apply:(Pass,EventStreamCollectedItem<Element>,inout Context)throws->EventStreamTreeTransformationResult<Element>
    ) rethrows -> EventStreamCollectedTree<Element> {
        var roots:[EventStreamCollectedItem<Element>]=[]
        for item in tree.roots {
            guard let current=try pipeline(item,using:passes,context:&context,apply:apply) else {continue}
            let children=try transform(current.subtree,using:passes,context:&context,apply:apply)
            roots.append(current.replacing(subtree:children))
        }
        // New tree initialization clears all caches even for an empty pipeline;
        // focus is copied verbatim, including a node removed from the items.
        return .init(roots:roots,duplicateReferencesSkipped:tree.duplicateReferencesSkipped,
                     depthLimitedReferencesSkipped:tree.depthLimitedReferencesSkipped,focusedElement:tree.focusedElement)
    }
    private static func pipeline<Element,Pass,Context>(
        _ item:EventStreamCollectedItem<Element>,using passes:[Pass],context:inout Context,
        apply:(Pass,EventStreamCollectedItem<Element>,inout Context)throws->EventStreamTreeTransformationResult<Element>
    ) rethrows -> EventStreamCollectedItem<Element>? {
        var current=item
        for pass in passes {
            switch try apply(pass,current,&context) {
            case .transformed(let next):current=next
            case .replaced(let replacement):return try pipeline(replacement,using:passes,context:&context,apply:apply)
            case .removed:return nil
            case .unchanged:break
            }
        }
        return current
    }
    static func transformMac<Backend:EventStreamMacTransformationBackend,Attributed:EventStreamAttributedTextBackend>(
        _ tree:EventStreamCollectedTree<Backend.Element>,using passes:[EventStreamMacTreeTransformation]=EventStreamMacTreeTransformation.defaultPipeline,
        context:inout EventStreamMacTransformationContext,backend:Backend,attributed:Attributed,
        format:(NSAttributedString,inout EventStreamMacTransformationContext)->EventStreamTransformedString,
        rebuild:((inout [EventStreamCollectedItem<Backend.Element>],EventStreamCollectedItem<Backend.Element>,inout EventStreamMacTransformationContext)->Void)?=nil,
        render:(EventStreamTransformedNode<Backend.Element>,inout EventStreamMacTransformationContext)throws->String
    ) throws -> EventStreamCollectedTree<Backend.Element> where Backend.Element==Attributed.Element {
        try transform(tree,using:passes,context:&context) {pass,item,current in
            try EventStreamMacTreeTransform.transform(item,pass:pass,context:&current,backend:backend,attributed:attributed,
                                                       format:format,rebuild:rebuild,render:render)
        }
    }
}
