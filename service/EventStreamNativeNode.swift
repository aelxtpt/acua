import Foundation
import ApplicationServices

@MainActor struct EventStreamNativeNodeBackend:EventStreamNodeBackend {
    typealias Element=EventStreamAXNode
    private let values=EventStreamNativeValueBackend()
    enum ReadError:Error {case accessibility(Int32)}
    func attributes(_ node:Element) -> [String:AnyObject] {node.cachedAttributesSnapshot()}
    func snapshot(_ node:Element) -> EventStreamValueSnapshot {values.snapshot(node)}
    func freshAttribute(_ attribute:String,of node:Element) -> AnyObject? {values.freshAttribute(attribute,of:node)}
    func freshSupportedAttributes(_ node:Element) -> Set<String> {values.freshSupportedAttributes(node)}
    func isValueSettable(_ node:Element) -> Bool {(try? isAttributeSettable("AXValue",of:node)) == true}
    func string(_ node:Element,for range:NSRange) -> String? {values.string(node,for:range)}
    func format(_ date:Date,style:EventStreamValueDateStyle) -> String {values.format(date,style:style)}
    func isAttributeSettable(_ attribute:String,of node:Element) throws -> Bool {
        var result=DarwinBoolean(false)
        let error=AXUIElementIsAttributeSettable(node.element,attribute as CFString,&result)
        guard error == .success else {throw ReadError.accessibility(error.rawValue)}
        return result.boolValue
    }
    func actions(_ node:Element) throws -> [String] {
        var names:CFArray?
        let error=AXUIElementCopyActionNames(node.element,&names)
        guard error == .success else {throw ReadError.accessibility(error.rawValue)}
        return (names as? [String]) ?? []
    }
    func actionDescription(_ name:String,of node:Element) throws -> String? {
        var description:CFString?
        let error=AXUIElementCopyActionDescription(node.element,name as CFString,&description)
        guard error == .success else {throw ReadError.accessibility(error.rawValue)}
        return description as String?
    }
}

@MainActor enum EventStreamNativeNode {
    static func construct(_ node:EventStreamAXNode,context:EventStreamNodeContext = .init()) -> EventStreamTransformedNode<EventStreamAXNode> {
        EventStreamNodeConstruction(backend:EventStreamNativeNodeBackend()).construct(node,context:context)
    }
}
