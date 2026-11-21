import Foundation
import ApplicationServices

@MainActor struct EventStreamNativeValueBackend:EventStreamValueBackend {
    typealias Element=EventStreamAXNode
    func snapshot(_ node:Element) -> EventStreamValueSnapshot {
        .init(role:node.cachedAttribute("AXRole") as? String ?? "AXUnknown",
              subrole:node.cachedAttribute("AXSubrole") as? String,value:node.cachedAttribute("AXValue"),
              coverage:node.cachedPartialValue("AXValue")?.string,supported:node.supportedAttributeNames(),
              transactionAttributes:node.transactionAttributes,visibleRange:range(node.cachedAttribute("AXVisibleCharacterRange")),
              dateTimeComponents:node.cachedAttribute("AXDateTimeComponents") as? Int)
    }
    func freshAttribute(_ attribute:String,of node:Element) -> AnyObject? {
        var value:CFTypeRef?
        return AXUIElementCopyAttributeValue(node.element,attribute as CFString,&value) == .success ? value:nil
    }
    func freshSupportedAttributes(_ node:Element) -> Set<String> {
        var names:CFArray?
        _ = AXUIElementCopyAttributeNames(node.element,&names)
        return Set((names as? [String]) ?? [])
    }
    func isValueSettable(_ node:Element) -> Bool {
        var result=DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(node.element,"AXValue" as CFString,&result) == .success && result.boolValue
    }
    func string(_ node:Element,for range:NSRange) -> String? {
        var range=CFRange(location:range.location == NSNotFound ? -1:range.location,length:range.length)
        guard let parameter=AXValueCreate(.cfRange,&range) else {return nil}
        var value:CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(node.element,"AXStringForRange" as CFString,parameter,&value) == .success else {return nil}
        return value as? String
    }
    func format(_ date:Date,style:EventStreamValueDateStyle) -> String {style.formatter().string(from:date)}
    private func range(_ raw:AnyObject?) -> NSRange? {
        guard let raw,CFGetTypeID(raw)==AXValueGetTypeID() else {return nil}
        let value=unsafeBitCast(raw,to:AXValue.self);var range=CFRange()
        guard AXValueGetType(value) == .cfRange,AXValueGetValue(value,.cfRange,&range) else {return nil}
        return NSRange(location:range.location == -1 ? NSNotFound:range.location,length:range.length)
    }
}

@MainActor enum EventStreamNativeValue {
    static func construct(_ node:EventStreamAXNode,context:EventStreamValueContext = .init()) -> EventStreamTransformedValue {
        EventStreamValueConstruction(backend:EventStreamNativeValueBackend()).construct(node,context:context)
    }
}
