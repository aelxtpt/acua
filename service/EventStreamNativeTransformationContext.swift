import AppKit
import ApplicationServices

// I/O is explicit so a hosted owner can supply bridge-aware calls.
// The built-in implementation below covers ordinary native AX only.
@MainActor struct EventStreamNativeTransformationContextIO {
    typealias BundleInfo=(String)->Any?
    var attribute:(AXUIElement,String)->AnyObject?
    var arrayCount:(AXUIElement,String)->(error:AXError,count:Int)
    var arrayValues:(AXUIElement,String,Int,Int)->AnyObject?
    var supported:(AXUIElement)->Set<String>
    var processIdentifier:(AXUIElement)throws->pid_t?
    var bundleInfo:(pid_t)->BundleInfo?
    static var native:Self {
        .init(attribute:{element,name in
            var value:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(element,name as CFString,&value)
            return [AXError.success,.noValue,.attributeUnsupported].contains(status) ? value:nil
        },arrayCount:{element,name in
            var count:CFIndex=0
            let status=AXUIElementGetAttributeValueCount(element,name as CFString,&count)
            return (status,count)
        },arrayValues:{element,name,index,maximum in
            var values:CFArray?
            // A returned array is retained regardless of copy status.
            _ = AXUIElementCopyAttributeValues(element,name as CFString,index,maximum,&values)
            return values
        },supported:{element in
            var names:CFArray?;_ = AXUIElementCopyAttributeNames(element,&names)
            return Set((names as? [String]) ?? [])
        },processIdentifier:{element in
            var pid:pid_t = -1
            return AXUIElementGetPid(element,&pid) == .success ? pid:nil
        },bundleInfo:{pid in
            guard let url=NSRunningApplication(processIdentifier:pid)?.bundleURL,let bundle=Bundle(url:url) else {return nil}
            return {bundle.object(forInfoDictionaryKey:$0)}
        })
    }
}

@MainActor struct EventStreamNativeTransformationContextBackend:EventStreamTransformationContextBackend {
    typealias Element=EventStreamAXNode
    private let io:EventStreamNativeTransformationContextIO
    init(io:EventStreamNativeTransformationContextIO?=nil) {self.io=io ?? .native}
    func isCatalystApp(_ application:Element)->Bool {
        typed(application,"_AXExhibitsMacCatalystBehavior",decode:{$0 as? Bool}) ?? false
    }
    func isWebShaped(_ application:Element)->Bool {
        guard let pid=try? io.processIdentifier(application.element),let read=io.bundleInfo(pid) else {return false}
        return EventStreamBundleShape.isWebShaped(read:read)
    }
    func firstChildHasChromeNodeID(_ window:Element)->Bool {
        // Uncached count, then uncached index0/max1,
        // even if the successful count is zero. Parent snapshot data is unused.
        guard io.arrayCount(window.element,"AXChildren").error == .success,
              let values=io.arrayValues(window.element,"AXChildren",0,1) as? [AnyObject] else {return false}
        // Malformed array members are dropped (compactMap) first.
        guard let first=values.first(where:{CFGetTypeID($0)==AXUIElementGetTypeID()}) else {return false}
        return io.supported(unsafeBitCast(first,to:AXUIElement.self)).contains("ChromeAXNodeId")
    }
    func frame(_ window:Element)->CGRect? {
        if let rect=typed(window,"AXFrame",decode:Self.rect) {return rect}
        guard let point=typed(window,"AXPosition",decode:Self.point),
              let size=typed(window,"AXSize",decode:Self.size) else {return nil}
        return .init(origin:point,size:size)
    }
    // Cached typed values win even outside advertised/requested attributes.
    // Fresh fallback honors metadata and never overwrites the source snapshot.
    private func typed<Value>(_ node:Element,_ name:String,decode:(AnyObject)->Value?)->Value? {
        if let cached=node.cachedAttribute(name),let value=decode(cached) {return value}
        guard node.mayReadAttribute(name),let fresh=io.attribute(node.element,name) else {return nil}
        return decode(fresh)
    }
    private static func rect(_ raw:AnyObject)->CGRect? {
        if CFGetTypeID(raw)==AXValueGetTypeID() {
            let value=unsafeBitCast(raw,to:AXValue.self);var rect=CGRect.zero
            return AXValueGetType(value) == .cgRect && AXValueGetValue(value,.cgRect,&rect) ? rect:nil
        }
        return raw as? CGRect
    }
    private static func point(_ raw:AnyObject)->CGPoint? {
        if CFGetTypeID(raw)==AXValueGetTypeID() {
            let value=unsafeBitCast(raw,to:AXValue.self);var point=CGPoint.zero
            return AXValueGetType(value) == .cgPoint && AXValueGetValue(value,.cgPoint,&point) ? point:nil
        }
        return raw as? CGPoint
    }
    private static func size(_ raw:AnyObject)->CGSize? {
        if CFGetTypeID(raw)==AXValueGetTypeID() {
            let value=unsafeBitCast(raw,to:AXValue.self);var size=CGSize.zero
            return AXValueGetType(value) == .cgSize && AXValueGetValue(value,.cgSize,&size) ? size:nil
        }
        return raw as? CGSize
    }
}

@MainActor enum EventStreamNativeTransformationContext {
    static func make(type:EventStreamElementContextType,application:EventStreamAXNode?,window:EventStreamAXNode?,
                     urlConfiguration:EventStreamURLShortener.Configuration?=nil,
                     backend:EventStreamNativeTransformationContextBackend?=nil)->EventStreamMacTransformationContext {
        EventStreamTransformationContextFactory.make(type:type,application:application,window:window,
            urlConfiguration:urlConfiguration,backend:backend ?? EventStreamNativeTransformationContextBackend())
    }
}

extension EventStreamNativeTreeTransformation {
    // Context creation for an already collected tree. The complete capture
    // factory still owns collection, transaction, focus/revisions and render
    // details; the native node description is supplied by default.
    @MainActor static func transform(
        _ tree:EventStreamCollectedTree<EventStreamAXNode>,type:EventStreamElementContextType,
        application:EventStreamAXNode?,window:EventStreamAXNode?,
        urlConfiguration:EventStreamURLShortener.Configuration?=nil,
        contextBackend:EventStreamNativeTransformationContextBackend?=nil,
        using passes:[EventStreamMacTreeTransformation]=EventStreamMacTreeTransformation.defaultPipeline,
        render:@MainActor (EventStreamTransformedNode<EventStreamAXNode>,inout EventStreamMacTransformationContext)throws->String = EventStreamNativeNodeRendering.description
    ) throws -> (tree:EventStreamCollectedTree<EventStreamAXNode>,context:EventStreamMacTransformationContext) {
        var context=EventStreamNativeTransformationContext.make(type:type,application:application,window:window,
            urlConfiguration:urlConfiguration,backend:contextBackend)
        let output=try transform(tree,using:passes,context:&context,render:render)
        return (output,context)
    }
}
