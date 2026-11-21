import AppKit
import ApplicationServices

// The notification name comes from String(describing:) on a nominal type
// with one CFString field and no custom description conformance. Keep the
// reflected field name, not rawValue.
private struct AXNotification {let name:CFString}

enum EventStreamAXNotificationDescription {
    static func describe(_ name:String)->String {
        String(describing:AXNotification(name:name as CFString))
    }
}

@MainActor
struct EventStreamNativeSelectionRecordIO {
    struct Application {
        var name:()->String?
        var processIdentifier:()->Int32
        var bundleIdentifier:()->String?
    }
    var attribute:(AXUIElement,String)->(status:AXError,value:AnyObject?)
    var parameterized:(AXUIElement,String,AnyObject)->(status:AXError,value:AnyObject?)
    var isMarkerRange:(AnyObject)->Bool
    var arrayCount:(AXUIElement,String)->(status:AXError,count:Int)
    var arrayValues:(AXUIElement,String,Int,Int)->(status:AXError,value:AnyObject?)
    var runningApplication:(AXUIElement)->Application?
    var secureInputPID:()->Int?

    static var native:Self {
        .init(attribute:{element,name in
            var value:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(element,name as CFString,&value)
            return (status,value)
        },parameterized:{element,name,parameter in
            var value:CFTypeRef?
            let status=AXUIElementCopyParameterizedAttributeValue(element,name as CFString,parameter,&value)
            return (status,value)
        },isMarkerRange:EventStreamTextMarkerSPI.isRange,arrayCount:{element,name in
            var count:CFIndex=0
            let status=AXUIElementGetAttributeValueCount(element,name as CFString,&count)
            return (status,count)
        },arrayValues:{element,name,index,maximum in
            var values:CFArray?
            let status=AXUIElementCopyAttributeValues(element,name as CFString,index,maximum,&values)
            return (status,values)
        },runningApplication:{element in
            var pid:pid_t = -1
            guard AXUIElementGetPid(element,&pid) == .success,
                  let app=NSRunningApplication(processIdentifier:pid) else {return nil}
            // Keep the same application object through all metadata reads.
            return .init(name:{app.localizedName},processIdentifier:{app.processIdentifier},
                         bundleIdentifier:{app.bundleIdentifier})
        },secureInputPID:{
            (CGSessionCopyCurrentDictionary() as? [String:Any])?["kCGSSessionSecureInputPID"] as? Int
        })
    }
}

// Ordinary native AX implementation of the recorder selection dependencies.
// Hosted bridge I/O must be supplied by its eventual owner; no native-PID
// fallback is invented for an explicitly supplied bridge-aware provider.
@MainActor
struct EventStreamNativeSelectionRecordBackend {
    struct Failure:Error {let status:AXError}
    private let io:EventStreamNativeSelectionRecordIO
    init(io:EventStreamNativeSelectionRecordIO?=nil) {self.io=io ?? .native}

    func string(_ node:EventStreamAXNode,attribute:String)->String? {
        typed(node,attribute) {$0 as? String}
    }

    func selectedRange(_ node:EventStreamAXNode)->EventStreamTextRange? {
        typed(node,"AXSelectedTextRange") {raw in
            guard CFGetTypeID(raw)==AXValueGetTypeID() else {return nil}
            let value=unsafeBitCast(raw,to:AXValue.self);var range=CFRange(location:0,length:0)
            guard AXValueGetType(value) == .cfRange,AXValueGetValue(value,.cfRange,&range) else {return nil}
            return .init(location:range.location,length:range.length)
        }
    }
    func selectedText(_ node:EventStreamAXNode)->String? {
        // Nonempty direct text wins. Missing/empty direct text
        // falls through to selectedTextMarkerRange and a parameterized read.
        if let text=string(node,attribute:"AXSelectedText"),!text.isEmpty {return text}
        guard let range:AnyObject=typed(node,"AXSelectedTextMarkerRange",decode:{io.isMarkerRange($0) ? $0:nil}) else {return nil}
        let result=io.parameterized(node.element,"AXStringForTextMarkerRange",range)
        // Throws for every non-success parameterized status.
        guard result.status == .success,let text=result.value as? String,!text.isEmpty else {return nil}
        return text
    }

    // Uses one running-application object, unlike the PID resolver. A
    // nameless application returns nil before secure-input reads.
    func application(_ node:EventStreamAXNode)->EventStreamApp? {
        guard let app=io.runningApplication(node.element),let name=app.name(),!name.isEmpty else {return nil}
        let securePID=app.processIdentifier()
        let secure=io.secureInputPID()==Int(securePID)
        let pid=app.processIdentifier()
        let bundle=app.bundleIdentifier().flatMap {$0.isEmpty ? nil:$0}
        return .init(name:name,secureInput:secure,processIdentifier:pid,bundleIdentifier:bundle)
    }

    // A present cached partial payload wins even when malformed; maximum
    // only affects a fresh read. A fresh read counts first, then requests
    // index0/maxValues unchanged even when the successful count is zero.
    func selectedItems(_ node:EventStreamAXNode,attribute:String,maximum:Int)throws->[EventStreamAXNode]? {
        if let raw=cached(node,attribute) {return decodeArray(raw,from:node)}
        guard node.mayReadAttribute(attribute) else {return nil}
        let count=io.arrayCount(node.element,attribute)
        guard count.status == .success else {
            if Self.ignored(count.status) {return nil}
            throw Failure(status:count.status)
        }
        let result=io.arrayValues(node.element,attribute,0,maximum)
        guard Self.ignored(result.status) else {throw Failure(status:result.status)}
        return result.value.flatMap {decodeArray($0,from:node)}
    }

    private func cached(_ node:EventStreamAXNode,_ name:String)->AnyObject? {
        node.cachedPartialValue(name)?.value ?? node.cachedAttribute(name)
    }
    private func typed<Value>(_ node:EventStreamAXNode,_ name:String,decode:(AnyObject)->Value?)->Value? {
        if let raw=cached(node,name),let value=decode(raw) {return value}
        guard node.mayReadAttribute(name) else {return nil}
        let result=io.attribute(node.element,name)
        guard Self.ignored(result.status) else {return nil}
        return result.value.flatMap(decode)
    }
    private static func ignored(_ status:AXError)->Bool {
        status == .success || status == .noValue || status == .attributeUnsupported
    }
    private func decodeArray(_ raw:AnyObject,from node:EventStreamAXNode)->[EventStreamAXNode]? {
        guard CFGetTypeID(raw)==CFArrayGetTypeID(),let values=raw as? [AnyObject] else {return nil}
        return values.compactMap {value in
            guard CFGetTypeID(value)==AXUIElementGetTypeID() else {return nil}
            return node.relatedNode(unsafeBitCast(value,to:AXUIElement.self))
        }
    }
}

extension EventStreamNativeContext {
    func makeSelectionRecordBuilder(nextIdentity:@escaping ()->EventStreamRecordIdentity,
                                    selectionBackend:EventStreamNativeSelectionRecordBackend?=nil)
      ->EventStreamSelectionRecordBuilder<EventStreamAXNode> {
        let selection=selectionBackend ?? .init()
        return .init(backend:.init(selectedRange:selection.selectedRange,selectedText:selection.selectedText,
            application:selection.application,window:resolver.window,
            target:{self.backend.describeEndpoint($0,titleOverride:nil)},
            selectedItems:{node,attribute,maximum in
                try selection.selectedItems(node,attribute:attribute,maximum:maximum)?.map(self.backend.describe)
            },nextIdentity:nextIdentity,notificationDescription:EventStreamAXNotificationDescription.describe))
    }
}

// Selection capture creates the UIElement before
// inspecting selection. This owner does the same and shares its snapshot-aware
// context with the recorder's input/tree paths and captured-URL dictionary.
@MainActor
final class EventStreamNativeSelectionRecordFactory {
    let snapshots:EventStreamNativeSnapshots
    let context:EventStreamNativeContext
    private let builder:EventStreamSelectionRecordBuilder<EventStreamAXNode>

    init(nextIdentity:@escaping ()->EventStreamRecordIdentity,
         snapshots:EventStreamNativeSnapshots?=nil,
         selectionBackend:EventStreamNativeSelectionRecordBackend?=nil) {
        let snapshots=snapshots ?? .init()
        self.snapshots=snapshots
        let context=EventStreamNativeContext(nodeProvider:{snapshots.node($0)})
        self.context=context
        builder=context.makeSelectionRecordBuilder(nextIdentity:nextIdentity,selectionBackend:selectionBackend)
    }

    func make(element:AXUIElement,notification:String)->EventStreamPendingSelectionRecord? {
        // Reject unrelated notifications before wrapping.
        guard notification=="AXSelectedTextChanged" ||
              EventStreamSelectionRecordBuilder<EventStreamAXNode>.selectedAttribute(notification) != nil else {return nil}
        return builder.make(element:snapshots.node(element),notification:notification)
    }
}
