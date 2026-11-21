import Foundation
import ApplicationServices
import Darwin

enum EventStreamNativeAttributedTextError:Error {
    case accessibility(Int32),typeMismatch(String),unavailableSPI,invalidRange
}

enum EventStreamTextMarkerSPI {
    private typealias TypeID = @convention(c) ()->CFTypeID
    private typealias CreateRange = @convention(c) (CFAllocator?,CFTypeRef,CFTypeRef)->Unmanaged<CFTypeRef>?
    private static let image=dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",RTLD_LAZY|RTLD_LOCAL)
    private static let markerType:TypeID?=load("AXTextMarkerGetTypeID",as:TypeID.self)
    private static let rangeType:TypeID?=load("AXTextMarkerRangeGetTypeID",as:TypeID.self)
    private static let create:CreateRange?=load("AXTextMarkerRangeCreate",as:CreateRange.self)
    private static func load<T>(_ name:String,as type:T.Type)->T? {
        guard let image,let symbol=dlsym(image,name) else {return nil}
        return unsafeBitCast(symbol,to:type)
    }
    static var available:Bool {markerType != nil && rangeType != nil && create != nil}
    static func isMarker(_ value:AnyObject)->Bool {markerType.map {CFGetTypeID(value)==$0()} ?? false}
    static func isRange(_ value:AnyObject)->Bool {rangeType.map {CFGetTypeID(value)==$0()} ?? false}
    static func range(start:AnyObject,end:AnyObject) throws -> AnyObject? {
        guard let create else {throw EventStreamNativeAttributedTextError.unavailableSPI}
        return create(nil,start,end)?.takeRetainedValue()
    }
}

// Explicit I/O also allows a hosted owner to supply bridge-aware
// operations. The default below covers ordinary native AX only.
@MainActor struct EventStreamNativeAttributedTextIO {
    var attribute:(AXUIElement,String)->AnyObject?
    var parameterized:(AXUIElement,String,AnyObject)throws->AnyObject?
    var supported:(AXUIElement)->Set<String>
    var parameterizedNames:(AXUIElement)->Set<String>
    var isMarker:(AnyObject)->Bool
    var isRange:(AnyObject)->Bool
    var makeRange:(AnyObject,AnyObject)throws->AnyObject?
    static var native:Self {
        .init(attribute:{element,name in
            var value:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(element,name as CFString,&value)
            return [AXError.success,.noValue,.attributeUnsupported].contains(status) ? value:nil
        },parameterized:{element,name,parameter in
            var value:CFTypeRef?
            let status=AXUIElementCopyParameterizedAttributeValue(element,name as CFString,parameter,&value)
            guard status == .success else {throw EventStreamNativeAttributedTextError.accessibility(status.rawValue)}
            return value
        },supported:{element in
            var names:CFArray?;_ = AXUIElementCopyAttributeNames(element,&names)
            return Set((names as? [String]) ?? [])
        },parameterizedNames:{element in
            var names:CFArray?;_ = AXUIElementCopyParameterizedAttributeNames(element,&names)
            return Set((names as? [String]) ?? [])
        },isMarker:EventStreamTextMarkerSPI.isMarker,isRange:EventStreamTextMarkerSPI.isRange,
        makeRange:{try EventStreamTextMarkerSPI.range(start:$0,end:$1)})
    }
}

@MainActor struct EventStreamNativeAttributedTextBackend:EventStreamAttributedTextBackend {
    typealias Element=EventStreamAXNode
    typealias Marker=AnyObject
    typealias MarkerRange=AnyObject
    private let io:EventStreamNativeAttributedTextIO
    private let snapshots:EventStreamNativeSnapshots
    init(io:EventStreamNativeAttributedTextIO?=nil,snapshots:EventStreamNativeSnapshots?=nil) {
        self.io=io ?? .native;self.snapshots=snapshots ?? .init()
    }
    func textualContext(_ element:Element)->String? {
        let name=EventStreamAttributedTextAttributes.textualContext
        if let value=element.cachedAttribute(name) as? String {return value}
        guard element.mayReadAttribute(name) else {return nil}
        return io.attribute(element.element,name) as? String
    }
    func supportsAttribute(_ attribute:String,of element:Element)->Bool {
        EventStreamAttributeAvailability.supports(attribute,supported:element.supportedAttributeNames(),
            requested:element.transactionAttributes,refresh:{io.supported(element.element)})
    }
    func parameterizedAttributes(_ element:Element)->Set<String> {io.parameterizedNames(element.element)}
    func captureElement(_ element:Element)->Element {snapshots.node(element.element)}
    func marker(_ attribute:String,of element:Element)->Marker? {
        if let value=element.cachedAttribute(attribute),io.isMarker(value) {return value}
        guard element.mayReadAttribute(attribute),let value=io.attribute(element.element,attribute),io.isMarker(value) else {return nil}
        return value
    }
    func markerRangeForElement(_ element:Element,parameter:Element) throws -> MarkerRange? {
        let name=EventStreamAttributedTextAttributes.rangeForElement
        guard let value=try io.parameterized(element.element,name,parameter.element) else {return nil}
        guard io.isRange(value) else {throw EventStreamNativeAttributedTextError.typeMismatch(name)}
        return value
    }
    func nextLineEnd(_ marker:Marker,of element:Element) throws -> Marker? {
        let name=EventStreamAttributedTextAttributes.nextLineEnd
        guard let value=try io.parameterized(element.element,name,marker) else {return nil}
        guard io.isMarker(value) else {throw EventStreamNativeAttributedTextError.typeMismatch(name)}
        return value
    }
    func makeMarkerRange(start:Marker,end:Marker) throws -> MarkerRange? {try io.makeRange(start,end)}
    func attributedString(_ range:NSRange,of element:Element) throws -> NSAttributedString? {
        var range=CFRange(location:range.location==NSNotFound ? -1:range.location,length:range.length)
        guard let parameter=AXValueCreate(.cfRange,&range) else {throw EventStreamNativeAttributedTextError.invalidRange}
        return try attributed(EventStreamAttributedTextAttributes.attributedRange,parameter:parameter,of:element)
    }
    func attributedString(_ range:MarkerRange,of element:Element,withOptions:Bool) throws -> NSAttributedString? {
        let name=withOptions ? EventStreamAttributedTextAttributes.attributedMarkerRangeWithOptions:EventStreamAttributedTextAttributes.attributedMarkerRange
        let parameter:AnyObject=withOptions ? ["AXTextMarkerRange":range,"AXSpellCheck":false] as NSDictionary:range
        return try attributed(name,parameter:parameter,of:element)
    }
    private func attributed(_ name:String,parameter:AnyObject,of element:Element) throws -> NSAttributedString? {
        guard let value=try io.parameterized(element.element,name,parameter) else {return nil}
        guard let attributed=value as? NSAttributedString else {throw EventStreamNativeAttributedTextError.typeMismatch(name)}
        return attributed
    }
}
