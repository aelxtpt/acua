import Foundation
import ApplicationServices

// Explicit I/O for ordinary AX. Hosted owner dispatch and its error domain
// remain separate dependencies rather than borrowing another process's data.
@MainActor struct EventStreamNativeSelectionIO {
    var count:(AXUIElement,String)->(AXError,Int)
    var value:(AXUIElement,String)->(AXError,AnyObject?)
    static var native:Self {
        .init(count:{element,name in
            var count:CFIndex=0
            let error=AXUIElementGetAttributeValueCount(element,name as CFString,&count)
            return (error,count)
        },value:{element,name in
            var value:CFTypeRef?
            let error=AXUIElementCopyAttributeValue(element,name as CFString,&value)
            return (error,value)
        })
    }
}

@MainActor struct EventStreamNativeSelection {
    private let io:EventStreamNativeSelectionIO
    private let capture:(AXUIElement)->EventStreamAXNode
    init(io:EventStreamNativeSelectionIO?=nil,snapshots:EventStreamNativeSnapshots?=nil,
         capture:((AXUIElement)->EventStreamAXNode)?=nil) {
        self.io=io ?? .native
        let reader=snapshots ?? EventStreamNativeSnapshots()
        // UIElement.init(element:) at0x10072C3E8 consults the CURRENT
        // TaskLocal, not the parent element's earlier related-node binding.
        self.capture=capture ?? {reader.node($0)}
    }
    //0x100771258/0x10077201C: first advertised positive-count candidate,
    // then decode that candidate only. Empty decoded arrays remain present.
    func elements(of node:EventStreamAXNode)->[EventStreamAXNode]? {
        let supported=node.supportedAttributeNames()
        for name in ["AXSelectedRows","AXSelectedCells","AXSelectedChildren"] where supported.contains(name) {
            let count:Int
            if let cached=node.cachedAttribute(name) {
                if let partial=node.cachedPartialValue(name)?.array {count=partial.count}
                else if CFGetTypeID(cached)==CFArrayGetTypeID() {count=CFArrayGetCount(unsafeBitCast(cached,to:CFArray.self))}
                else {continue}
            } else {
                let (error,result)=io.count(node.element,name)
                guard error == .success else {continue}
                count=result
            }
            guard count>0 else {continue}
            if let cached=decode(node.cachedAttribute(name)) {return cached}
            guard node.mayReadAttribute(name) else {return nil}
            let (error,value)=io.value(node.element,name)
            guard [AXError.success,.noValue,.attributeUnsupported].contains(error) else {return nil}
            return decode(value)
        }
        return nil
    }
    private func decode(_ raw:AnyObject?)->[EventStreamAXNode]? {
        guard let raw,CFGetTypeID(raw)==CFArrayGetTypeID(),let values=raw as? [AnyObject] else {return nil}
        //0x10071E134 ->0x1006F4DF8 compactMaps invalid array members.
        return values.compactMap {value in
            guard CFGetTypeID(value)==AXUIElementGetTypeID() else {return nil}
            return capture(unsafeBitCast(value,to:AXUIElement.self))
        }
    }
}

@MainActor enum EventStreamNativeTreeFocus {
    static func make(_ tree:inout EventStreamCollectedTree<EventStreamAXNode>,
                     context:EventStreamMacTransformationContext,
                     selection:EventStreamNativeSelection?=nil,snapshots:EventStreamNativeSnapshots?=nil)
        ->EventStreamCollectedTree<EventStreamAXNode>? {
        let reader=snapshots ?? EventStreamNativeSnapshots()
        let selection=selection ?? .init(snapshots:reader)
        return EventStreamTreeFocus.make(&tree,selected:{selection.elements(of:$0.element)},
            identity:{EventStreamSnapshotAXIdentity(element:$0.element)},recapture:{source in
                let context=EventStreamNodeContext(kind:context.type.rawValue,isCatalyst:context.isCatalyst,
                    isWebShaped:context.isWebShaped,isChromium:context.isChromium,windowFrame:context.windowFrame)
                return EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend(snapshots:reader)).collect(source,context:context)
            })
    }
}
