import ApplicationServices
import Foundation

@MainActor struct EventStreamNativeAttributedMarkdown {
    private let capture:(AXUIElement)->EventStreamAXNode
    init(capture:((AXUIElement)->EventStreamAXNode)?=nil) {
        if let capture {self.capture=capture}
        else {let snapshots=EventStreamNativeSnapshots();self.capture={snapshots.node($0)}}
    }
    func describe(_ value:Any)->EventStreamAttributedElementDescription {
        let raw=value as AnyObject
        precondition(CFGetTypeID(raw)==AXUIElementGetTypeID(),"attributed element must be AXUIElement")
        let node=capture(unsafeBitCast(raw,to:AXUIElement.self))
        // These four native getters consult the newly captured attributes only.
        return .init(role:node.cachedAttribute("AXRole") as? String ?? "AXUnknown",
            url:node.cachedAttribute("AXURL") as? URL,
            description:node.cachedAttribute("AXDescription") as? String,
            roleDescription:node.cachedAttribute("AXRoleDescription") as? String)
    }
    func format(_ text:NSAttributedString,context:inout EventStreamMacTransformationContext)->EventStreamTransformedString {
        EventStreamAttributedMarkdown.format(text,shortener:&context.urlShortener,describe:describe)
    }
}

extension EventStreamMacTreeTransform {
    // Explicit native attributed entry for passes11/12. The outer native tree
    // owner still supplies traversal, transaction and reconstruction lifetime.
    @MainActor static func transformAttributed(
        _ item:EventStreamCollectedItem<EventStreamAXNode>,pass:EventStreamMacTreeTransformation,
        context:inout EventStreamMacTransformationContext,backend:EventStreamNativeMacTransformationBackend,
        attributed:EventStreamNativeAttributedTextBackend,formatter:EventStreamNativeAttributedMarkdown,
        render:(EventStreamTransformedNode<EventStreamAXNode>,inout EventStreamMacTransformationContext)throws->String
    ) throws -> EventStreamTreeTransformationResult<EventStreamAXNode> {
        try transform(item,pass:pass,context:&context,backend:backend,attributed:attributed,
                      format:formatter.format,render:render)
    }
}
