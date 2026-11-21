import Foundation

struct EventStreamMacTransformationContext {
    var type:EventStreamElementContextType
    var isCatalyst=false
    var isWebShaped=false
    var isChromium=false
    var windowFrame:CGRect?
    var urlShortener:EventStreamURLShortener
}

enum EventStreamMacTreeTransformation:Equatable {
    case shared(EventStreamSharedTreeTransformation)
    case filterActions,removeElementsUnderCalendarEvents
    case retrieveAttributedTextFromTextAreas,retrieveAttributedTextFromWebAreas
    var rawTag:UInt8 {
        switch self {
        case .shared(let pass):return pass.rawValue
        case .filterActions:return 9
        case .removeElementsUnderCalendarEvents:return 10
        case .retrieveAttributedTextFromTextAreas:return 11
        case .retrieveAttributedTextFromWebAreas:return 12
        }
    }
    init?(rawTag:UInt8) {
        if let shared=EventStreamSharedTreeTransformation(rawValue:rawTag) {self = .shared(shared);return}
        switch rawTag {
        case 9:self = .filterActions
        case 10:self = .removeElementsUnderCalendarEvents
        case 11:self = .retrieveAttributedTextFromTextAreas
        case 12:self = .retrieveAttributedTextFromWebAreas
        default:return nil
        }
    }
    static var defaultPipeline:[Self] {
        [.filterActions]+EventStreamSharedTreeTransformation.defaultPipeline.map(Self.shared)
            + [.removeElementsUnderCalendarEvents,.retrieveAttributedTextFromTextAreas,.retrieveAttributedTextFromWebAreas]
    }
}

enum EventStreamScrollAxis:Equatable {case horizontal,vertical}
enum EventStreamMacTreeTransformationError:Error,Equatable {
    case unsupportedTransformation(EventStreamMacTreeTransformation)
}

@MainActor protocol EventStreamMacTransformationBackend:EventStreamTitleAssociationBackend {
    func title(for identity:Identity) -> String?
    func hasScrollBar(_ axis:EventStreamScrollAxis,of element:Element) -> Bool
    func applicationBundleIdentifier(of element:Element) -> String?
}

@MainActor enum EventStreamMacTreeTransform {
    // Native wrapper. This is one-item dispatch, not the outer
    // traversal/reconstruction driver. This generic overload has no attributed
    // backend; the acquisition overload/native attributed entry supplies it.
    static func transform<Backend:EventStreamMacTransformationBackend>(
        _ item:EventStreamCollectedItem<Backend.Element>,pass:EventStreamMacTreeTransformation,
        context:inout EventStreamMacTransformationContext,backend:Backend,
        rebuild:((inout [EventStreamCollectedItem<Backend.Element>],EventStreamCollectedItem<Backend.Element>,inout EventStreamMacTransformationContext)->Void)?=nil,
        render:(EventStreamTransformedNode<Backend.Element>,inout EventStreamMacTransformationContext)throws->String
    ) throws -> EventStreamTreeTransformationResult<Backend.Element> {
        switch pass {
        case .shared(let shared):
            // The first array is loaded children, not actions.
            // Interesting actions, focusability, selectability and enabled
            // state do not protect a leaf from this additional native gate.
            if shared == .pruneNonDescriptiveSubtrees,context.type != .fullUIContext,
               item.children.isEmpty,!item.node.hasDescriptiveAttributes,
               !item.node.isFocused,!item.node.isSelected,!item.node.isDisclosing {return .removed}
            if shared == .flattenLinksIntoMarkdownText || shared == .mergeTextOnlySiblings {
                return try EventStreamSharedTreeTransform.transform(item,pass:shared,contextType:context.type,shortener:&context.urlShortener)
            }
            return try EventStreamSharedTreeTransform.transform(item,pass:shared,context:&context,
                titleAssociation:backend,providerTitle:{backend.title(for:$0)},rebuild:rebuild,render:render)
        case .filterActions:
            guard context.type == .fullUIContext else {return .unchanged}
            var node=item.node
            node.actionDescriptions=item.node.actionDescriptions.filter {action in
                switch action.name {
                case "AXShowAlternateUI","AXShowDefaultUI":return false
                case "AXCancel":return !context.isCatalyst && !["AXMenuBar","AXMenuItem"].contains(node.role)
                case "AXPick":return node.role != "AXMenuItem"
                case "AXConfirm":return node.role != "AXTextField"
                case "AXIncrement","AXDecrement":return !node.isValueSettable
                case "AXScrollLeftByPage","AXScrollRightByPage":return backend.hasScrollBar(.horizontal,of:node.element)
                case "AXScrollUpByPage","AXScrollDownByPage":return backend.hasScrollBar(.vertical,of:node.element)
                default:return true
                }
            }
            // Return transformed even when the list is unchanged.
            return .transformed(item.replacing(node:node))
        case .removeElementsUnderCalendarEvents:
            guard item.node.role=="AXStaticText",item.node.roleDescription=="Event",item.children.count==1,
                  item.children[0].node.role=="AXStaticText",
                  backend.applicationBundleIdentifier(of:item.node.element)=="com.apple.iCal" else {return .unchanged}
            return .transformed(item.replacing(children:[]))
        case .retrieveAttributedTextFromTextAreas,.retrieveAttributedTextFromWebAreas:
            throw EventStreamMacTreeTransformationError.unsupportedTransformation(pass)
        }
    }
}
