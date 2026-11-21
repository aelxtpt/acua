import Foundation
import ApplicationServices

// Native LM-readable node description, bound through the
// AccessibilityNode witness template. This renders a transformed
// node; tree focus selection, revision IDs/diffs and render details have other
// owners and are not produced here.
@MainActor enum EventStreamNativeNodeRendering {
    static func description(_ node:EventStreamTransformedNode<EventStreamAXNode>,
                            context:inout EventStreamMacTransformationContext)->String {
        let role=EventStreamPresentationRole(nativeRole:node.role,roleDescription:node.roleDescription)
        let kind=context.type.rawValue
        var presentation=EventStreamPresentation()
        // Return before reading ranges or mutating the shortener
        // when informational context suppresses the attributes.
        if role.includesAttributes(contextKind:kind,hasDescriptiveAttributes:node.hasDescriptiveAttributes) {
            let rows=indexRange(node.element.cachedAttribute("AXRowIndexRange"))
            let columns=indexRange(node.element.cachedAttribute("AXColumnIndexRange"))
            presentation=node.presentation(trimURL:{context.urlShortener.trim(url:$0,isImage:node.role=="AXImage")},
                                           rows:rows,columns:columns)
        }
        return presentation.accessibilityDescription(role:role,state:node.presentationState,
            contextKind:kind,hasDescriptiveAttributes:node.hasDescriptiveAttributes)
    }

    // Captured values only, typed CFRange (not NSRange), with
    // location...location+length-1. Singletons, negative starts and overflow
    // are omitted. A missing/malformed range is not fetched.
    static func indexRange(_ raw:AnyObject?)->ClosedRange<Int>? {
        guard let raw else {return nil}
        let range:CFRange
        if CFGetTypeID(raw)==AXValueGetTypeID() {
            let value=unsafeBitCast(raw,to:AXValue.self);var decoded=CFRange()
            guard AXValueGetType(value) == .cfRange,AXValueGetValue(value,.cfRange,&decoded) else {return nil}
            range=decoded
        } else {
            guard let decoded=raw as? CFRange else {return nil}
            range=decoded
        }
        guard range.location>=0,range.length>1 else {return nil}
        let (end,overflow)=range.location.addingReportingOverflow(range.length-1)
        guard !overflow else {return nil}
        return range.location...end
    }
}
