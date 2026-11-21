import Foundation

extension EventStreamTransformedNode {
    // Native overrides, not the more permissive protocol defaults.
    var hasDescriptiveAttributes:Bool {
        [title,description,value,placeholderValue].contains { !($0 ?? "").isEmpty } || role=="AXImage"
    }
    var isFocusableOrSelectable:Bool {isFocusable || isSelectable}
    var hasInterestingActions:Bool {
        actionDescriptions.contains {$0.name != "AXScrollToVisible" && $0.name != "AXShowMenu"}
    }
    var canBeUserInteractive:Bool {
        switch role {
        case "AXStaticText":return isFocusableOrSelectable
        case "AXTextArea","AXGroup":return isFocusable
        default:return true
        }
    }
}

extension EventStreamCollectedItem {
    // Root followed by subtree in depth-first order; trim each
    // value, discard empty strings, and join the rest with a newline.
    func flattenedString(_ value:(EventStreamTransformedNode<Element>)->String?) -> String {
        var pending=[self],strings:[String]=[]
        while let item=pending.popLast() {
            let text=(value(item.node) ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            if !text.isEmpty {strings.append(text)}
            pending.append(contentsOf:item.children.reversed())
        }
        return strings.joined(separator:"\n")
    }
    var hasDescriptiveAttributes:Bool {
        !flattenedString(\.description).isEmpty || !flattenedString(\.value).isEmpty
            || !flattenedString(\.title).isEmpty || !flattenedString(\.placeholderValue).isEmpty
            || node.role=="AXImage"
    }
    fileprivate func hasProtectedDescendant() -> Bool {
        var pending=Array(children.reversed())
        while let item=pending.popLast() {
            if item.node.isFocusableOrSelectable || item.node.hasInterestingActions {return true}
            pending.append(contentsOf:item.children.reversed())
        }
        return false
    }
}

// Raw values and default ordering are fixed. Only the two
// pruning decisions are implemented here. Calling another pass fails explicitly;
// this is not the complete shared/Mac transformation pipeline.
enum EventStreamSharedTreeTransformation:UInt8,CaseIterable {
    case associateTitleUIElements=0,flattenIntoSelectableAncestor,pruneNonDescriptiveSubtrees,
         pruneEmptyDisabledElements,mergeSingleItemGroups,flattenRedundantHierarchy,
         flattenRepetitiveStaticText,flattenLinksIntoMarkdownText,mergeTextOnlySiblings
    static let defaultPipeline:[Self]=allCases
}
enum EventStreamTreePruningError:Error,Equatable {
    case unsupportedTransformation(EventStreamSharedTreeTransformation)
}
enum EventStreamTreePruningDecision:Equatable {case removed,unchanged}

enum EventStreamTreePruning {
    // Shared transform cases 2 and 3. Deliberately evaluates one already-built
    // item: traversal/rebuild order belongs to the remaining pipeline driver.
    static func decision<Element>(for item:EventStreamCollectedItem<Element>,
                                  pass:EventStreamSharedTreeTransformation) throws -> EventStreamTreePruningDecision {
        switch pass {
        case .pruneNonDescriptiveSubtrees:
            return item.node.isFocusableOrSelectable || item.node.hasInterestingActions
                || item.hasDescriptiveAttributes || item.hasProtectedDescendant() ? .unchanged:.removed
        case .pruneEmptyDisabledElements:
            return !item.node.isEnabled && !item.node.isFocused && item.children.isEmpty
                && !item.hasDescriptiveAttributes ? .removed:.unchanged
        default:throw EventStreamTreePruningError.unsupportedTransformation(pass)
        }
    }
}
