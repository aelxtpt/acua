import Foundation

enum EventStreamAttributedTextAttributes {
    static let textualContext="AXTextualContext",sourceCode="AXTextualContextSourceCode"
    static let chromeNodeID="ChromeAXNodeId"
    static let startMarker="AXStartTextMarker",endMarker="AXEndTextMarker"
    static let nextLineEnd="AXNextLineEndTextMarkerForTextMarker"
    static let rangeForElement="AXTextMarkerRangeForUIElement"
    static let attributedRange="AXAttributedStringForRange"
    static let attributedMarkerRange="AXAttributedStringForTextMarkerRange"
    static let attributedMarkerRangeWithOptions="AXAttributedStringForTextMarkerRangeWithOptions"
}

@MainActor protocol EventStreamAttributedTextBackend {
    associatedtype Element
    associatedtype Marker
    associatedtype MarkerRange
    func textualContext(_ element:Element) -> String?
    func supportsAttribute(_ attribute:String,of element:Element) -> Bool
    func parameterizedAttributes(_ element:Element) -> Set<String>
    func captureElement(_ element:Element) -> Element
    func marker(_ attribute:String,of element:Element) -> Marker?
    func markerRangeForElement(_ element:Element,parameter:Element) throws -> MarkerRange?
    func nextLineEnd(_ marker:Marker,of element:Element) throws -> Marker?
    func makeMarkerRange(start:Marker,end:Marker) throws -> MarkerRange?
    func attributedString(_ range:NSRange,of element:Element) throws -> NSAttributedString?
    func attributedString(_ range:MarkerRange,of element:Element,withOptions:Bool) throws -> NSAttributedString?
}

@MainActor enum EventStreamAttributedTextAcquisition {
    //0x100764168 cases11/12 and helpers0x100765760/0x100765A44.
    // Acquisition errors become absence; the web next-line probe deliberately
    // continues on errors, but a present typed marker skips extraction.
    static func acquire<Backend:EventStreamAttributedTextBackend>(
        _ node:EventStreamTransformedNode<Backend.Element>,pass:EventStreamMacTreeTransformation,
        type:EventStreamElementContextType,backend:Backend
    ) throws -> NSAttributedString? {
        typealias A=EventStreamAttributedTextAttributes
        switch pass {
        case .retrieveAttributedTextFromTextAreas:
            guard node.role=="AXTextArea" else {return nil}
            guard backend.textualContext(node.element) != A.sourceCode,let value=node.value else {return nil}
            if let range=node.truncationRange {return try? backend.attributedString(range,of:node.element)}
            if backend.parameterizedAttributes(node.element).contains(A.attributedMarkerRangeWithOptions) {
                let fresh=backend.captureElement(node.element)
                guard let range=try? backend.markerRangeForElement(node.element,parameter:fresh) else {return nil}
                return try? backend.attributedString(range,of:node.element,withOptions:true)
            }
            return try? backend.attributedString(NSRange(location:0,length:value.utf16.count),of:node.element)
        case .retrieveAttributedTextFromWebAreas:
            guard type == .informationalContext,node.role=="AXWebArea" else {return nil}
            guard !backend.supportsAttribute(A.chromeNodeID,of:node.element),
                  let start=backend.marker(A.startMarker,of:node.element),
                  let end=backend.marker(A.endMarker,of:node.element) else {return nil}
            if (try? backend.nextLineEnd(end,of:node.element)) != nil {return nil}
            guard let range=try? backend.makeMarkerRange(start:start,end:end) else {return nil}
            let options=backend.parameterizedAttributes(node.element).contains(A.attributedMarkerRangeWithOptions)
            return try? backend.attributedString(range,of:node.element,withOptions:options)
        default:throw EventStreamMacTreeTransformationError.unsupportedTransformation(pass)
        }
    }
}

extension EventStreamMacTreeTransform {
    // The exact rich-run formatter is a required dependency. No plain-text
    // formatter or identity fallback is installed for the missing native one.
    @MainActor static func transform<Backend:EventStreamMacTransformationBackend,Attributed:EventStreamAttributedTextBackend>(
        _ item:EventStreamCollectedItem<Backend.Element>,pass:EventStreamMacTreeTransformation,
        context:inout EventStreamMacTransformationContext,backend:Backend,attributed:Attributed,
        format:(NSAttributedString,inout EventStreamMacTransformationContext)->EventStreamTransformedString,
        rebuild:((inout [EventStreamCollectedItem<Backend.Element>],EventStreamCollectedItem<Backend.Element>,inout EventStreamMacTransformationContext)->Void)?=nil,
        render:(EventStreamTransformedNode<Backend.Element>,inout EventStreamMacTransformationContext)throws->String
    ) throws -> EventStreamTreeTransformationResult<Backend.Element> where Attributed.Element==Backend.Element {
        guard pass == .retrieveAttributedTextFromTextAreas || pass == .retrieveAttributedTextFromWebAreas else {
            return try transform(item,pass:pass,context:&context,backend:backend,rebuild:rebuild,render:render)
        }
        guard let text=try EventStreamAttributedTextAcquisition.acquire(item.node,pass:pass,type:context.type,backend:attributed) else {return .unchanged}
        let rich=format(text,&context)
        var node=item.node
        node.attributedString=text;node.transformedString=rich;node.value=rich.description
        // Text areas retain loaded children; WebAreas clear them after a
        // successful conversion. Neither path rewrites source/subset metadata.
        return .transformed(pass == .retrieveAttributedTextFromWebAreas ? item.replacing(node:node,children:[]):item.replacing(node:node))
    }
}
