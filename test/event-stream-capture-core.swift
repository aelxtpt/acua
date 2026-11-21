import Foundation
import ApplicationServices

@MainActor final class RawCaptureModelBackend:EventStreamRawCaptureBackend {
    typealias Element=Int
    typealias Identity=Int
    var log:[String]=[]
    var source=EventStreamCollectedTree<Int>(roots:[])
    var electron=false,selected:Int?,menu:Int?=7,screenshot=false
    var mutateOnFocus:((inout EventStreamCollectedTree<Int>)->Void)?
    func identity(_ source:Int)->Int {source}
    func isElectronApp(_ application:Int)->Bool {log.append("electron");return electron}
    func selectedWebArea(in window:Int)->Int? {log.append("selected\(window)");return selected}
    func collect(_ root:Int,context:EventStreamMacTransformationContext)->EventStreamCollectedTree<Int> {log.append("collect\(root)");return source}
    func menuBar(of application:Int)->Int? {log.append("menu\(application)");return menu}
    func appendImmediateMenu(_ menu:Int,to tree:inout EventStreamCollectedTree<Int>,context:inout EventStreamMacTransformationContext) {
        log.append("append\(menu)");tree.roots.append(.init(node:.init(element:menu),path:[],children:[],childrenSubset:nil))
    }
    func focusTree(_ tree:inout EventStreamCollectedTree<Int>,context:EventStreamMacTransformationContext)->EventStreamCollectedTree<Int>? {
        log.append("focus");mutateOnFocus?(&tree);return EventStreamTreeFocus.wrap(tree,selectedItems:[])
    }
    func screenshotNeeded(_ tree:EventStreamCollectedTree<Int>,application:Int)->Bool {log.append("screenshot");return screenshot}
}

@main enum CaptureCoreTests {
    typealias Tree=EventStreamCollectedTree<Int>
    typealias Item=EventStreamCollectedItem<Int>
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func item(_ id:Int,role:String="AXStaticText",url:URL?=nil,value:String?=nil,children:[Item]=[])->Item {
        var node=EventStreamTransformedNode(element:id);node.role=role;node.url=url;node.value=value
        return .init(node:node,path:[id],children:children,childrenSubset:nil)
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let backend=RawCaptureModelBackend()
        var context=EventStreamMacTransformationContext(type:.eventStreamContext,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
        backend.source=Tree(roots:[item(1,children:[item(2,value:"captured")])])
        func prepare(root:Int=1,window:Int=1,focus:Int?=nil,cache:Tree?=nil,force:Bool=false)->EventStreamPreparedRawCapture<Int> {
            try! EventStreamRawCaptureCore.prepare(root:root,window:window,application:9,focusedElement:focus,cachedTree:cache,
                context:&context,alwaysIncludeScreenshot:force,backend:backend)
        }
        let first=prepare()
        check("common raw phase order uses Electron check before collection",backend.log==["electron","collect1","menu9","append7","focus","screenshot"])
        check("root equal to window appends application menu",first.main.roots.map(\.node.element)==[1,7])
        check("absent ordinary focus does not manufacture a focus tree",first.focus==nil && first.main.focusedElement==nil)
        backend.log=[]
        _=prepare(root:9)
        check("application-root equality does not activate window menu branch",!backend.log.contains("menu9") && !backend.log.contains("append7"))
        context.type = .informationalContext;backend.log=[]
        _=prepare()
        check("informational capture still queries application menu",backend.log.contains("menu9"))
        check("informational capture skips actual menu append",!backend.log.contains("append7"))
        context.type = .eventStreamContext;backend.menu=nil;backend.log=[]
        let forced=prepare(force:true)
        check("force screenshot preserves focus extraction but skips screenshot policy",forced.screenshotNeededForContext && backend.log.last=="focus" && !backend.log.contains("screenshot"))
        backend.screenshot=true
        check("ordinary screenshot result is retained",prepare().screenshotNeededForContext)
        backend.screenshot=false
        var cached=backend.source;cached.focusedElement=item(501,value:"cached focus").node
        _=cached.table(identity:{$0.element});backend.log=[]
        let retained=prepare(cache:cached)
        check("validated raw cache skips root collection",!backend.log.contains("collect1"))
        check("nil focus without Electron selection retains cached independent focus",retained.main.focusedElement?.element==501 && retained.focus?.focusedElement?.element==501)
        check("source cache is not mutated by copied preparation",cached.focusedElement?.element==501 && cached.hasCachedTable)
        backend.log=[]
        let found=prepare(focus:2,cache:cached)
        check("supplied focus skips Electron detection and fallback",!backend.log.contains("electron") && !backend.log.contains("selected1"))
        check("supplied focus resolves captured node rather than manufacturing source",found.main.focusedElement?.element==2 && found.main.focusedElement?.value=="captured")
        check("focus lookup fills the raw identity table",found.main.hasCachedTable)
        let missed=prepare(focus:404,cache:cached)
        check("missing supplied focus clears previous independent focus",missed.main.focusedElement==nil && missed.focus==nil)
        let duplicate=Tree(roots:[item(2,value:"first"),item(2,value:"last")],focusedElement:item(700).node)
        check("duplicate raw identity uses last table occurrence",prepare(focus:2,cache:duplicate).main.focusedElement?.value=="last")
        backend.electron=true;backend.selected=2;backend.log=[]
        let selected=prepare(cache:cached)
        check("Electron fallback searches the supplied window before other phases",backend.log.prefix(2)==["electron","selected1"])
        check("Electron selected source resolves within cached raw forest",selected.main.focusedElement?.value=="captured")
        backend.selected=nil
        check("unsuccessful Electron fallback keeps cached independent focus",prepare(cache:cached).main.focusedElement?.element==501)
        backend.selected=404
        check("found Electron source absent from raw forest clears focus",prepare(cache:cached).main.focusedElement==nil)
        backend.electron=false
        let a=URL(string:"https://first.test")!,b=URL(string:"https://second.test")!
        let urls=Tree(roots:[item(3,role:"AXWebArea"),item(4,url:b,children:[item(5,role:"AXWebArea",url:a)]),item(6,role:"AXWebArea",url:b)],focusedElement:item(8,role:"AXWebArea",url:b).node)
        check("raw URL lookup skips empty WebArea and follows preorder",prepare(cache:urls).webAreaURL==a)
        check("non-WebArea URL is not window metadata",prepare(cache:Tree(roots:[item(1,url:b)])).webAreaURL==nil)
        check("independent focused node URL is not scanned",prepare(cache:Tree(roots:[],focusedElement:item(8,role:"AXWebArea",url:b).node)).webAreaURL==nil)
        backend.mutateOnFocus={tree in tree.roots.append(item(10,role:"AXWebArea",url:b))}
        check("URL lookup runs after raw focus extraction",prepare(cache:Tree(roots:[])).webAreaURL==b)
        backend.mutateOnFocus=nil

        // Actual native source adapter with controlled AX values. Creating
        // references does not read or control another process's live UI.
        var nativeNodes:[EventStreamSnapshotAXIdentity:EventStreamAXNode]=[:]
        var values:[EventStreamSnapshotAXIdentity:[String:AnyObject]]=[:],reads:[String]=[]
        let refs=(0..<5).map {AXUIElementCreateApplication(Int32(20000+$0))}
        let keys=refs.map {EventStreamSnapshotAXIdentity(element:$0)}
        for i in refs.indices {
            nativeNodes[keys[i]]=EventStreamAXNode(refs[i],supportedAttributes:["AXChildren","AXRole","AXSelectedTextRange","AXSelectedTextMarkerRange"],related:{nativeNodes[.init(element:$0)]!})
        }
        func range(_ length:Int,_ location:Int=0)->AnyObject {
            var raw=CFRange(location:location,length:length);return AXValueCreate(.cfRange,&raw)!
        }
        func set(_ index:Int,_ map:[String:AnyObject]) {values[keys[index]]=map}
        let marker=NSString(string:"controlled marker range")
        var principal:Any?="AtomApplication"
        let io=EventStreamNativeCaptureSourceIO(attribute:{element,name in
            let key=EventStreamSnapshotAXIdentity(element:element),index=keys.firstIndex(of:key)!
            reads.append("\(index):\(name)");return values[key]?[name]
        },bundleInfo:{_ in {name in reads.append(name);return principal}},isMarkerRange:{$0===marker})
        let native=EventStreamNativeRawCaptureBackend(io:io),root=nativeNodes[keys[0]]!
        check("native Electron adapter reads exact principal class",native.isElectronApp(root) && reads==["NSPrincipalClass"])
        principal="BrowserCrApplication"
        check("Chromium principal does not substitute for Electron",!native.isElectronApp(root))
        principal="atomapplication"
        check("Electron principal comparison is case-sensitive",!native.isElectronApp(root))
        principal=NSNumber(value:true)
        check("non-string principal does not classify Electron",!native.isElectronApp(root))
        set(0,["AXChildren":[refs[1],refs[2]] as NSArray,"AXRole":"AXWebArea" as NSString,"AXSelectedTextRange":range(9)])
        set(1,["AXRole":"AXGroup" as NSString,"AXChildren":[refs[3]] as NSArray])
        set(2,["AXRole":"AXWebArea" as NSString,"AXSelectedTextRange":range(2)])
        set(3,["AXRole":"AXWebArea" as NSString,"AXSelectedTextRange":range(3)])
        reads=[]
        check("native descendant search prefers shallower selected WebArea",native.selectedWebArea(in:root) === nativeNodes[keys[2]])
        check("native descendant excludes receiver and stops before deeper selection",!reads.contains("0:AXRole") && !reads.contains("3:AXRole"))
        check("positive range short-circuits marker and child reads",!reads.contains("2:AXSelectedTextMarkerRange") && !reads.contains("2:AXChildren"))
        set(2,["AXRole":"AXWebArea" as NSString,"AXSelectedTextRange":range(0),"AXSelectedTextMarkerRange":marker]);reads=[]
        check("present marker accepts zero-length selected text",native.selectedWebArea(in:root) === nativeNodes[keys[2]] && reads.contains("2:AXSelectedTextMarkerRange"))
        set(2,["AXRole":"axwebarea" as NSString,"AXSelectedTextRange":range(2)]);reads=[]
        check("native role comparison is exact and rejected nodes still descend",native.selectedWebArea(in:root) === nativeNodes[keys[3]])
        check("nonmatching role does not evaluate selected text",!reads.contains("2:AXSelectedTextRange"))
        set(0,["AXChildren":[refs[2]] as NSArray]);set(2,["AXRole":"AXWebArea" as NSString,"AXSelectedTextRange":range(2,-10)]);reads=[]
        check("selected predicate tests length without inventing a location guard",native.selectedWebArea(in:root) === nativeNodes[keys[2]])
        set(0,["AXChildren":[refs[1],refs[1]] as NSArray]);set(1,["AXRole":"AXGroup" as NSString]);reads=[]
        check("native search does not deduplicate repeated descendants",native.selectedWebArea(in:root)==nil && reads.filter {$0=="1:AXRole"}.count==2)
        set(0,["AXChildren":[NSString(string:"malformed"),refs[2]] as NSArray]);reads=[]
        check("native child decoding skips malformed array members",native.selectedWebArea(in:root) === nativeNodes[keys[2]])
        let cachedRoot=EventStreamAXNode(refs[0],supportedAttributes:[],attributes:["AXChildren":[refs[2]] as NSArray],related:{nativeNodes[.init(element:$0)]!})
        reads=[]
        check("typed cached children win outside advertised attribute set",native.selectedWebArea(in:cachedRoot) === nativeNodes[keys[2]] && !reads.contains("0:AXChildren"))
        print("EVENT STREAM RAW CAPTURE CORE: \(checks) checks passed")
    }
}
