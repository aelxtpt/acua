import ApplicationServices
import Foundation

@MainActor
final class EventStreamAXNode {
        let element: AXUIElement
        private var accessed: Set<String> = []
        private var attributes: [String: AnyObject] = [:]
        private let supportedAttributes: Set<String>?
        private let partialValues: [String:EventStreamPartialValue]
        private let related: ((AXUIElement) -> EventStreamAXNode)?
        private let attributeReader: ((String) -> AnyObject?)?
        let transactionAttributes: Set<String>?
        init(_ element: AXUIElement, supportedAttributes: Set<String>? = nil,
             attributes: [String:AnyObject] = [:], transactionAttributes: Set<String>? = nil,
             partialValues: [String:EventStreamPartialValue] = [:],
             related: ((AXUIElement) -> EventStreamAXNode)? = nil,
             attributeReader: ((String) -> AnyObject?)? = nil) {
            self.element = element;self.supportedAttributes=supportedAttributes
            self.attributes=attributes;self.accessed=Set(attributes.keys)
            self.transactionAttributes=transactionAttributes
            self.partialValues=partialValues;self.related=related
            self.attributeReader=attributeReader
        }
        func cachedAttribute(_ name: String) -> AnyObject? { attributes[name] }
        func cachedAttributesSnapshot() -> [String:AnyObject] { attributes }
        func cachedPartialValue(_ name: String) -> EventStreamPartialValue? { partialValues[name] }
        func relatedNode(_ element: AXUIElement) -> EventStreamAXNode { related?(element) ?? EventStreamAXNode(element) }
        func supportedAttributeNames() -> Set<String> {
            if let supportedAttributes {return supportedAttributes}
            var names:CFArray?
            _ = AXUIElementCopyAttributeNames(element,&names)
            return Set((names as? [String]) ?? [])
        }
        func mayReadAttribute(_ name:String) -> Bool {
            guard let supportedAttributes else {return true}
            return EventStreamAttributeAvailability.mayRead(name,supported:supportedAttributes,requested:transactionAttributes)
        }
        func attribute(_ name: String) -> AnyObject? {
            guard mayReadAttribute(name) else {return nil}
            if accessed.insert(name).inserted {
                if let attributeReader {attributes[name]=attributeReader(name);return attributes[name]}
                var result: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success {
                    attributes[name] = result
                }
            }
            return attributes[name]
        }
}

// Native adapter for element descriptions. Node attributes persist for a
// snapshot; refresh creates another node around the same native AX reference.
@MainActor
enum EventStreamAXContext {
    static func describe(_ element: AXUIElement) -> EventStreamAXElement {
        reader().describe(EventStreamAXNode(element))
    }

    static func reader() -> EventStreamAXContent<EventStreamAXNode> {
        EventStreamAXContent<EventStreamAXNode>(string: { $0.attribute($1) as? String },
            numberOfCharacters: { $0.attribute("AXNumberOfCharacters") as? Int }, visibleRange: { node in
                guard let raw = node.attribute("AXVisibleCharacterRange"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
                let value = unsafeDowncast(raw, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
                      range.location >= 0, range.length >= 0 else { return nil }
                return NSRange(location: range.location, length: range.length)
            }, stringForRange: { node, range in
                var native = CFRange(location: range.location, length: range.length)
                guard let parameter = AXValueCreate(.cfRange, &native) else { return nil }
                var result: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(node.element, "AXStringForRange" as CFString, parameter, &result) == .success else { return nil }
                return result as? String
            }, children: { node, count in
                var result: CFArray?
                guard AXUIElementCopyAttributeValues(node.element, "AXChildren" as CFString, 0, count, &result) == .success,
                      let elements = result as? [AnyObject] else { return [] }
                return elements.compactMap { raw in
                    guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                    return node.relatedNode(unsafeDowncast(raw, to: AXUIElement.self))
                }
            })
    }
}
