import Foundation

@MainActor protocol EventStreamTitleAssociationBackend {
    associatedtype Element
    associatedtype Identity:Hashable
    func identity(_ element:Element) -> Identity
    func titleTargets(_ element:Element) -> [Identity]
}

extension EventStreamSharedTreeTransform {
    // Shared transform case 0. Identity and AXServesAsTitleForUIElements belong
    // to the source backend, not to the mutable presentation fields.
    @MainActor static func transform<Backend:EventStreamTitleAssociationBackend,Context>(
        _ item:EventStreamCollectedItem<Backend.Element>,pass:EventStreamSharedTreeTransformation,
        context:inout Context,titleAssociation:Backend,
        providerTitle:((Backend.Identity)->String?)?=nil,
        rebuild:((inout [EventStreamCollectedItem<Backend.Element>],EventStreamCollectedItem<Backend.Element>,inout Context)->Void)?=nil,
        render:(EventStreamTransformedNode<Backend.Element>,inout Context)throws->String
    ) throws -> EventStreamTreeTransformationResult<Backend.Element> {
        guard pass == .associateTitleUIElements else {
            return try transform(item,pass:pass,context:&context,rebuild:rebuild,render:render)
        }
        var children=item.children,changed=false
        // Iterate the source children, but locate/edit their current siblings.
        // Items moved under an earlier source are not processed again here.
        for original in item.children {
            let sourceID=titleAssociation.identity(original.node.element)
            guard let sourceIndex=children.firstIndex(where:{titleAssociation.identity($0.node.element)==sourceID}) else {continue}
            var seen:Set<Backend.Identity>=[]
            let targets=titleAssociation.titleTargets(original.node.element).filter {seen.insert($0).inserted}
            guard !targets.isEmpty else {continue}
            let fields=[original.node.value,original.node.title,original.node.description].compactMap {$0}
            if targets.count==1,fields.count==1 {
                let targetID=targets[0]
                let hasNoTitle:Bool
                if let providerTitle {hasNoTitle=providerTitle(targetID)==nil}
                else {
                    // Fallback consults the source sibling snapshot. A
                    // title assigned earlier in this pass does not block it.
                    hasNoTitle=item.children.first(where:{titleAssociation.identity($0.node.element)==targetID})?.node.title==nil
                }
                if hasNoTitle,let targetIndex=children.firstIndex(where:{titleAssociation.identity($0.node.element)==targetID}) {
                    let target=children[targetIndex]
                    var node=target.node;node.title=fields[0]
                    children[targetIndex] = target.replacing(node:node)
                    children.remove(at:sourceIndex);changed=true
                    continue
                }
            }
            // Failed/ambiguous title copying falls through to grouping. This
            // gate tests the unedited source, not its edited current children.
            guard original.children.isEmpty else {continue}
            let indices=targets.compactMap {id in children.firstIndex(where:{titleAssociation.identity($0.node.element)==id})}
            guard indices.count==targets.count else {continue}
            for index in indices {
                // Fetch each target after the previous append. Self-targets
                // consequently observe the same value-copy behavior as native.
                let target=children[index],source=children[sourceIndex]
                var nested=source.children
                if let rebuild {rebuild(&nested,target,&context)} else {nested.append(target)}
                children[sourceIndex] = source.replacing(children:nested)
            }
            for index in indices.sorted(by:>) {children.remove(at:index)}
            changed=true
        }
        return changed ? .transformed(item.replacing(children:children)):.unchanged
    }
}
