import Foundation
import AppKit
import ApplicationServices

@MainActor protocol EventStreamRawCaptureBackend {
    associatedtype Element
    associatedtype Identity:Hashable
    func identity(_ source:Element)->Identity
    func isElectronApp(_ application:Element)->Bool
    func selectedWebArea(in window:Element)->Element?
    func collect(_ root:Element,context:EventStreamMacTransformationContext)throws->EventStreamCollectedTree<Element>
    func menuBar(of application:Element)->Element?
    func appendImmediateMenu(_ menu:Element,to tree:inout EventStreamCollectedTree<Element>,context:inout EventStreamMacTransformationContext)
    func focusTree(_ tree:inout EventStreamCollectedTree<Element>,context:EventStreamMacTransformationContext)->EventStreamCollectedTree<Element>?
    func screenshotNeeded(_ tree:EventStreamCollectedTree<Element>,application:Element)->Bool
}

struct EventStreamPreparedRawCapture<Element> {
    var main:EventStreamCollectedTree<Element>
    var focus:EventStreamCollectedTree<Element>?
    var webAreaURL:URL?
    var screenshotNeededForContext:Bool
}

@MainActor enum EventStreamRawCaptureCore {
    // Common owner0x100245594. Parent owns source/cache validation, current
    // transaction, enablement/restoration and invalidation monitor lifetime.
    static func prepare<Backend:EventStreamRawCaptureBackend>(
        root:Backend.Element,window:Backend.Element,application:Backend.Element,
        focusedElement:Backend.Element?,cachedTree:EventStreamCollectedTree<Backend.Element>?,
        context:inout EventStreamMacTransformationContext,alwaysIncludeScreenshot:Bool,backend:Backend
    )throws->EventStreamPreparedRawCapture<Backend.Element> {
        var focused=focusedElement
        if focused==nil,backend.isElectronApp(application) {focused=backend.selectedWebArea(in:window)}
        var tree=try cachedTree ?? backend.collect(root,context:context)
        if backend.identity(root)==backend.identity(window),let menu=backend.menuBar(of:application),context.type != .informationalContext {
            backend.appendImmediateMenu(menu,to:&tree,context:&context)
        }
        if let focused {setFocus(focused,in:&tree,identity:backend.identity)}
        let focus=backend.focusTree(&tree,context:context)
        let screenshot=alwaysIncludeScreenshot || backend.screenshotNeeded(tree,application:application)
        let url=tree.preorder.lazy.compactMap {item in item.node.role=="AXWebArea" ? item.node.url:nil}.first
        return .init(main:tree,focus:focus,webAreaURL:url,screenshotNeededForContext:screenshot)
    }

    private static func setFocus<Element,Identity:Hashable>(_ source:Element,in tree:inout EventStreamCollectedTree<Element>,identity:(Element)->Identity) {
        let table=tree.table(identity:{identity($0.element)})
        guard let position=table.values[identity(source)],let path=table.paths[position],let first=path.first,tree.roots.indices.contains(first) else {
            tree.focusedElement=nil;return
        }
        var item=tree.roots[first]
        for index in path.dropFirst() {
            guard item.children.indices.contains(index) else {tree.focusedElement=nil;return}
            item=item.children[index]
        }
        tree.focusedElement=item.node
    }
}

@MainActor struct EventStreamNativeCaptureSourceIO {
    var attribute:(AXUIElement,String)->AnyObject?
    var bundleInfo:(AXUIElement)->EventStreamNativeTransformationContextIO.BundleInfo?
    var isMarkerRange:(AnyObject)->Bool
    static var native:Self {
        .init(attribute:{element,name in
            var raw:CFTypeRef?
            let error=AXUIElementCopyAttributeValue(element,name as CFString,&raw)
            return [AXError.success,.noValue,.attributeUnsupported].contains(error) ? raw:nil
        },bundleInfo:{element in
            var pid:pid_t = -1
            guard AXUIElementGetPid(element,&pid) == .success,
                  let url=NSRunningApplication(processIdentifier:pid)?.bundleURL,let bundle=Bundle(url:url) else {return nil}
            return {bundle.object(forInfoDictionaryKey:$0)}
        },isMarkerRange:EventStreamTextMarkerSPI.isRange)
    }
}

@MainActor struct EventStreamNativeRawCaptureBackend:EventStreamRawCaptureBackend {
    typealias Element=EventStreamAXNode
    typealias Identity=EventStreamSnapshotAXIdentity
    let snapshots:EventStreamNativeSnapshots
    let io:EventStreamNativeCaptureSourceIO
    let checkpoint:() throws -> Void
    init(snapshots:EventStreamNativeSnapshots?=nil,io:EventStreamNativeCaptureSourceIO?=nil,
         checkpoint:@escaping () throws -> Void = {}) {
        self.snapshots=snapshots ?? .init();self.io=io ?? .native;self.checkpoint=checkpoint
    }
    func identity(_ source:Element)->Identity {.init(element:source.element)}
    func isElectronApp(_ application:Element)->Bool {io.bundleInfo(application.element)?("NSPrincipalClass") as? String == "AtomApplication"}
    func collect(_ root:Element,context:EventStreamMacTransformationContext)throws->EventStreamCollectedTree<Element> {
        try EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend(snapshots:snapshots)).collect(root,context:nodeContext(context),checkpoint:checkpoint)
    }
    func menuBar(of application:Element)->Element? {typed(application,"AXMenuBar",decode:{reference($0,from:application)})}
    func appendImmediateMenu(_ menu:Element,to tree:inout EventStreamCollectedTree<Element>,context:inout EventStreamMacTransformationContext) {
        let nodeContext=nodeContext(context)
        var items:[EventStreamCollectedItem<Element>]=[]
        for (index,source) in children(menu).enumerated() where index != 0 {
            if let title=typed(source,"AXTitle",decode:{$0 as? String}),title.contains("Debug") {continue}
            var node=EventStreamNativeNode.construct(snapshots.node(source.element),context:nodeContext)
            node.actionDescriptions=[]
            items.append(.init(node:node,path:[],children:[],childrenSubset:nil))
        }
        let root=EventStreamNativeNode.construct(snapshots.node(menu.element),context:nodeContext)
        tree.roots.append(.init(node:root,path:[],children:items,childrenSubset:nil))
    }
    func focusTree(_ tree:inout EventStreamCollectedTree<Element>,context:EventStreamMacTransformationContext)->EventStreamCollectedTree<Element>? {
        EventStreamNativeTreeFocus.make(&tree,context:context,snapshots:snapshots)
    }
    func screenshotNeeded(_ tree:EventStreamCollectedTree<Element>,application:Element)->Bool {
        EventStreamNativeScreenshotContextPolicy.needed(tree,application:application)
    }
    func selectedWebArea(in window:Element)->Element? {
        //0x1007C0E40: breadth-first, excludes receiver, no identity dedup.
        var level=children(window)
        while !level.isEmpty {
            var next:[Element]=[]
            for source in level {
                if typed(source,"AXRole",decode:{$0 as? String})=="AXWebArea",hasSelection(source) {return source}
                next.append(contentsOf:children(source))
            }
            level=next
        }
        return nil
    }
    private func hasSelection(_ source:Element)->Bool {
        if let range=typed(source,"AXSelectedTextRange",decode:{raw -> CFRange? in
            guard CFGetTypeID(raw)==AXValueGetTypeID() else {return nil}
            let value=unsafeBitCast(raw,to:AXValue.self);var result=CFRange(location:0,length:0)
            guard AXValueGetType(value) == .cfRange,AXValueGetValue(value,.cfRange,&result) else {return nil}
            return result
        }),range.length>0 {return true}
        return typed(source,"AXSelectedTextMarkerRange",decode:{io.isMarkerRange($0) ? $0:nil}) != nil
    }
    private func children(_ source:Element)->[Element] {
        typed(source,"AXChildren",decode:{raw in
            (raw as? [AnyObject]).map {$0.compactMap {reference($0,from:source)}}
        }) ?? []
    }
    private func reference(_ raw:AnyObject,from source:Element)->Element? {
        guard CFGetTypeID(raw)==AXUIElementGetTypeID() else {return nil}
        return source.relatedNode(unsafeBitCast(raw,to:AXUIElement.self))
    }
    private func typed<Value>(_ source:Element,_ name:String,decode:(AnyObject)->Value?)->Value? {
        if let raw=source.cachedAttribute(name),let value=decode(raw) {return value}
        guard source.mayReadAttribute(name),let raw=io.attribute(source.element,name) else {return nil}
        return decode(raw)
    }
    private func nodeContext(_ context:EventStreamMacTransformationContext)->EventStreamNodeContext {
        .init(kind:context.type.rawValue,isCatalyst:context.isCatalyst,isWebShaped:context.isWebShaped,
              isChromium:context.isChromium,windowFrame:context.windowFrame)
    }
}

@MainActor enum EventStreamNativeCaptureCore {
    struct Result {
        let revision:EventStreamNativeTreeRevision.Revision
        let copyMenuItemIsEnabled=false
        let webAreaURL:URL?
        let contextType:EventStreamElementContextType
        let screenshotNeededForContext:Bool
    }
    // Ordinary AX common core. Full parent captureTree binding, transaction /
    // cache validation, monitor, enablement and hosted I/O are not supplied here.
    static func capture(root:EventStreamAXNode,window:EventStreamAXNode,application:EventStreamAXNode,
                        focusedElement:EventStreamAXNode?=nil,cachedTree:EventStreamCollectedTree<EventStreamAXNode>?=nil,
                        previous:EventStreamNativeTreeRevision.Revision?=nil,context:inout EventStreamMacTransformationContext,
                        alwaysIncludeScreenshot:Bool=false,enableAXDiffing:Bool=true,
                        backend:EventStreamNativeRawCaptureBackend?=nil)throws->Result {
        let backend=backend ?? .init()
        let raw=try EventStreamRawCaptureCore.prepare(root:root,window:window,application:application,focusedElement:focusedElement,
            cachedTree:cachedTree,context:&context,alwaysIncludeScreenshot:alwaysIncludeScreenshot,backend:backend)
        let transformed=try EventStreamNativeCaptureTransformation.run(main:raw.main,focus:raw.focus,context:&context,snapshots:backend.snapshots)
        let revision=try EventStreamNativeCaptureTransformation.revision(transformed,previous:previous,enableAXDiffing:enableAXDiffing,context:&context)
        return .init(revision:revision,webAreaURL:raw.webAreaURL,contextType:context.type,screenshotNeededForContext:raw.screenshotNeededForContext)
    }
}
