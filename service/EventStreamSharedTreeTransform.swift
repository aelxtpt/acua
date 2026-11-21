import Foundation

// Shared Result tags are transformed=0, replaced=1, removed=2, unchanged=3.
// The tree driver restarts the whole item pipeline for replacement; an ordinary
// transformation continues with the next pass and its edited item.
enum EventStreamTreeTransformationResult<Element> {
    case transformed(EventStreamCollectedItem<Element>)
    case replaced(EventStreamCollectedItem<Element>)
    case removed
    case unchanged
    var rawTag:UInt8 {
        switch self {case .transformed:return 0;case .replaced:return 1;case .removed:return 2;case .unchanged:return 3}
    }
}

enum EventStreamSharedTreeTransform {
    // Shared transform cases 1-6 only. The renderer and its mutable context
    // are required inputs; there is no native renderer or identity fallback.
    static func transform<Element,Context>(_ item:EventStreamCollectedItem<Element>,
        pass:EventStreamSharedTreeTransformation,context:inout Context,
        rebuild:((inout [EventStreamCollectedItem<Element>],EventStreamCollectedItem<Element>,inout Context)->Void)?=nil,
        render:(EventStreamTransformedNode<Element>,inout Context)throws->String
    ) throws -> EventStreamTreeTransformationResult<Element> {
        switch pass {
        case .flattenIntoSelectableAncestor:
            guard item.node.isSelectable,!item.node.isFocused,item.node.role != "AXTable",
                  item.node.subrole != "AXTableRow" else {return .unchanged}
            var pending=Array(item.children.reversed()),descendants:[EventStreamCollectedItem<Element>]=[]
            while let child=pending.popLast() {
                guard !child.node.isValueSettable,!child.node.isSelectable else {return .unchanged}
                descendants.append(child);pending.append(contentsOf:child.children.reversed())
            }
            var node=item.node
            node.isFocusable=descendants.contains { $0.node.isFocusable }
            node.value=item.flattenedString(\.stringValue)
            node.description=item.flattenedString(\.description)
            node.title=item.flattenedString(\.title)
            var children:[EventStreamCollectedItem<Element>]=[]
            // Witness31 is boolValue: Optional<Bool>. Its nil tag is 2;
            // both false and true survive. This is independent of role.
            // Filter a full preorder traversal; preserving a parent does not
            // skip its descendants or deduplicate their retained subtrees.
            for child in descendants where child.node.capturedValueIsBooleanConvertible {
                if let rebuild {rebuild(&children,child,&context)}
                else {children.append(child)}
            }
            return .transformed(item.replacing(node:node,children:children))
        case .pruneNonDescriptiveSubtrees,.pruneEmptyDisabledElements:
            return try EventStreamTreePruning.decision(for:item,pass:pass) == .removed ? .removed:.unchanged
        case .mergeSingleItemGroups:
            guard item.node.role=="AXGroup",!item.node.isSelectable,!item.node.isFocused,
                  !item.node.hasDescriptiveAttributes else {return .unchanged}
            if item.children.count==1,let child=item.children.first,child.childrenSubset?.availableRanges==nil {
                return .replaced(child)
            }
            return item.children.isEmpty ? .removed:.unchanged
        case .flattenRedundantHierarchy:
            guard !item.node.isSelectable,!item.node.isFocused,!item.node.hasDescriptiveAttributes else {return .unchanged}
            // A parent render failure returns unchanged.
            guard let parentText=try? render(item.node,&context) else {return .unchanged}
            var children=item.children
            for index in item.children.indices.reversed() {
                let child=item.children[index]
                guard child.node.role==item.node.role,child.childrenSubset?.availableRanges==nil else {continue}
                // A child render failure skips this child and
                // continues leftward, preserving earlier edits/context changes.
                if let text=try? render(child.node,&context),text==parentText {
                    children.replaceSubrange(index...index,with:child.children)
                }
            }
            // Return transformed even when no child was removed.
            return .transformed(item.replacing(children:children))
        case .flattenRepetitiveStaticText:
            guard !item.node.isFocusable,!item.node.isSelectable else {return .unchanged}
            var descendants=Array(item.children.reversed())
            while let child=descendants.popLast() {
                guard !child.node.canBeUserInteractive else {return .unchanged}
                descendants.append(contentsOf:child.children.reversed())
            }
            // Match direct child description/value against the
            // corresponding parent string, collect indices right-to-left, then
            // splice. Repeat whole rounds until no matching layer remains.
            let description=item.node.description,value=item.node.stringValue
            func matches(_ raw:String?,in parent:String?) -> Bool {
                guard let raw,let parent else {return false}
                let text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
                return !text.isEmpty && parent.contains(text)
            }
            var children=item.children,changed=false
            while true {
                let indices=children.indices.reversed().filter {
                    matches(children[$0].node.description,in:description) || matches(children[$0].node.value,in:value)
                }
                guard !indices.isEmpty else {break}
                changed=true
                for index in indices {children.replaceSubrange(index...index,with:children[index].children)}
            }
            return changed ? .transformed(item.replacing(children:children)):.unchanged
        default:throw EventStreamTreePruningError.unsupportedTransformation(pass)
        }
    }
}
