import Foundation
import ApplicationServices

@main enum EventStreamNativeRendererTests {
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")}
        checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        func context(_ type:EventStreamElementContextType = .fullUIContext,
                     _ configuration:EventStreamURLShortener.Configuration?=nil)->EventStreamMacTransformationContext {
            .init(type:type,urlShortener:.init(configuration:configuration ?? .init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
        }
        func source(_ attributes:[String:AnyObject]=[:])->EventStreamAXNode {
            .init(AXUIElementCreateApplication(getpid()),supportedAttributes:[],attributes:attributes,
                  transactionAttributes:[],attributeReader:{_ in fatalError("renderer must not fetch attributes")})
        }
        func node(_ role:String="AXUnknown",_ description:String?=nil,_ attributes:[String:AnyObject]=[:])->EventStreamTransformedNode<EventStreamAXNode> {
            var value=EventStreamTransformedNode(element:source(attributes));value.role=role;value.roleDescription=description;return value
        }
        func range(_ location:Int,_ length:Int)->AnyObject {
            var value=CFRange(location:location,length:length);return AXValueCreate(.cfRange,&value)!
        }
        var c=context(),n=node()
        check("missing role description retains full-context unknown",EventStreamNativeNodeRendering.description(n,context:&c)=="unknown")
        c=context(.informationalContext)
        check("informational context suppresses missing role label",EventStreamNativeNodeRendering.description(n,context:&c).isEmpty)
        n=node("AXButton","Botão");n.title="Abrir";n.isEnabled=false
        c=context()
        check("native binding combines localized role state and attributes",EventStreamNativeNodeRendering.description(n,context:&c)=="Botão (disabled) Abrir")
        n.domClassList=["outgoing","is-sender","message"]
        check("native DOM class supplies sent-by-me presentation state",n.presentationState.isSentByMe)
        check("native sent-by-me flag reaches rendered state",EventStreamNativeNodeRendering.description(n,context:&c)=="Botão (disabled, sent by me) Abrir")
        n.domClassList=["IS-SENDER","is-sender-extra"," is-sender","is-sender "]
        check("sender class equality is case and whitespace sensitive",!n.presentationState.isSentByMe)
        n.domClassList=[];check("empty DOM classes do not imply sender",!n.presentationState.isSentByMe)
        n.domClassList=nil;check("absent DOM classes do not imply sender",!n.presentationState.isSentByMe)
        n=node("AXRow","linha");n.isSelected=true;n.isEnabled=false;n.isDisclosable=true;n.isDisclosing=true
        n.valueTypeName="number";n.isValueSettable=true;n.domClassList=["is-sender"]
        check("native state binding preserves every marker and ordering",EventStreamNativeNodeRendering.description(n,context:&c)=="row (selected, disabled, expanded, settable, number, sent by me)")

        check("AX range is converted to inclusive last index",EventStreamNativeNodeRendering.indexRange(range(0,4))==0...3)
        check("nonzero range keeps its location",EventStreamNativeNodeRendering.indexRange(range(7,2))==7...8)
        check("singleton AX range is omitted",EventStreamNativeNodeRendering.indexRange(range(5,1))==nil)
        check("empty AX range is omitted",EventStreamNativeNodeRendering.indexRange(range(5,0))==nil)
        check("negative length is omitted",EventStreamNativeNodeRendering.indexRange(range(5,-1))==nil)
        check("negative start is omitted",EventStreamNativeNodeRendering.indexRange(range(-1,4))==nil)
        check("signed end overflow is omitted",EventStreamNativeNodeRendering.indexRange(range(Int.max,2))==nil)
        check("largest valid inclusive end survives",EventStreamNativeNodeRendering.indexRange(range(Int.max-1,2))==(Int.max-1)...Int.max)
        check("large valid length does not materialize indices",EventStreamNativeNodeRendering.indexRange(range(0,Int.max))==0...(Int.max-1))
        check("missing raw range stays absent",EventStreamNativeNodeRendering.indexRange(nil)==nil)
        check("boxed typed CFRange follows the conditional cast",EventStreamNativeNodeRendering.indexRange(CFRange(location:2,length:3) as AnyObject)==2...4)
        check("NSRange is not decoded as an index range",EventStreamNativeNodeRendering.indexRange(NSRange(location:2,length:3) as AnyObject)==nil)
        check("NSValue range does not substitute for CFRange",EventStreamNativeNodeRendering.indexRange(NSValue(range:.init(location:2,length:3)))==nil)
        check("string and null ranges do not coerce",EventStreamNativeNodeRendering.indexRange("2-4" as NSString)==nil && EventStreamNativeNodeRendering.indexRange(NSNull())==nil)
        var point=CGPoint(x:2,y:3)
        check("wrong AXValue type is omitted",EventStreamNativeNodeRendering.indexRange(AXValueCreate(.cgPoint,&point)!)==nil)
        var error=AXError.attributeUnsupported
        check("AX error value does not become a range",EventStreamNativeNodeRendering.indexRange(AXValueCreate(.axError,&error)!)==nil)
        check("AX reference does not become a range",EventStreamNativeNodeRendering.indexRange(AXUIElementCreateApplication(getpid()))==nil)
        n=node("AXCell","cell",["AXRowIndexRange":range(0,4),"AXColumnIndexRange":range(5,3)])
        n.title="0-3";n.value="0-3";c=context()
        check("captured table ranges bypass value dedup with inclusive ends",EventStreamNativeNodeRendering.description(n,context:&c)=="cell 0-3, Rows: 0-3, Columns: 5-7")
        check("native renderer leaves captured range representation unchanged",CFGetTypeID(n.element.cachedAttribute("AXRowIndexRange")!)==AXValueGetTypeID())
        n=node("AXCell","cell",["AXRowIndexRange":"bad" as NSString]);n.title="A"
        check("malformed captured range never triggers fresh AX read",EventStreamNativeNodeRendering.description(n,context:&c)=="cell A")
        n=node("AXCell","cell")
        check("uncached range never triggers fresh AX read",EventStreamNativeNodeRendering.description(n,context:&c)=="cell")

        let url=URL(string:"https://www.example.test/a?x=1#tail")!
        n=node("AXLink","link");n.url=url;c=context()
        check("native URL uses the mutable context shortener",EventStreamNativeNodeRendering.description(n,context:&c)=="link example.test/a?x=1#tail")
        check("rendered URL updates domain accounting and seen URLs",c.urlShortener.urls==[url] && c.urlShortener.domains==["example.test":1] && c.urlShortener.accumulated=="example.test/a?x=1#tail".count)
        _ = EventStreamNativeNodeRendering.description(n,context:&c)
        check("repeated native renders consume URL budget again",c.urlShortener.urls.count==1 && c.urlShortener.domains["example.test"]==2 && c.urlShortener.accumulated==2*"example.test/a?x=1#tail".count)
        n.title="example.test/a?x=1#tail";c=context()
        check("deduplicated URL still consumes its context budget",EventStreamNativeNodeRendering.description(n,context:&c)=="link example.test/a?x=1#tail" && c.urlShortener.accumulated>0)
        c=context(.eventStreamContext,.init(individualLimit:nil,totalLimit:0,includeQuery:true,includeFragment:true))
        n.title=nil
        check("native renderer honors total URL budget ellipsis",EventStreamNativeNodeRendering.description(n,context:&c)=="link …" && c.urlShortener.accumulated==1)
        c=context(.fullUIContext,.init(individualLimit:nil,totalLimit:nil,includeQuery:false,includeFragment:false))
        check("native renderer honors query and fragment configuration",EventStreamNativeNodeRendering.description(n,context:&c)=="link example.test/a")
        n=node("AXImage","image");n.url=url;c=context(.informationalContext)
        check("image role suppresses the displayed URL",EventStreamNativeNodeRendering.description(n,context:&c)=="image")
        check("image URL remains recorded without consuming budget",c.urlShortener.urls==[url] && c.urlShortener.accumulated==0 && c.urlShortener.domains.isEmpty)
        n.role="axImage";c=context()
        check("image comparison uses exact native role equality",EventStreamNativeNodeRendering.description(n,context:&c)=="image example.test/a?x=1#tail")
        n=node("AXLink","link");n.url=URL(string:"data:text/plain,hello")!;c=context()
        check("rejected data URL records discovery but renders no attribute",EventStreamNativeNodeRendering.description(n,context:&c)=="link" && c.urlShortener.urls==[n.url!] && c.urlShortener.accumulated==0)
        n.url=URL(fileURLWithPath:"/tmp/native-renderer.txt");c=context(.fullUIContext,.init(individualLimit:1,totalLimit:0,includeQuery:false,includeFragment:false))
        check("file URL bypasses native render budgets",EventStreamNativeNodeRendering.description(n,context:&c)=="link file:///tmp/native-renderer.txt" && c.urlShortener.accumulated==0)

        n=node("AXMenu",nil);n.title="hidden";n.url=url;c=context(.informationalContext)
        check("informational menu hides attributes before URL accounting",EventStreamNativeNodeRendering.description(n,context:&c)=="menu" && c.urlShortener.urls.isEmpty)
        n=node("AXMenuBar","menu bar");n.url=url
        check("informational menu bar also leaves URL untouched",EventStreamNativeNodeRendering.description(n,context:&c)=="menu bar" && c.urlShortener.urls.isEmpty)
        n=node("AXButton","button");n.help="help alone";n.url=url
        check("help and URL do not make a button descriptive",EventStreamNativeNodeRendering.description(n,context:&c)=="button" && c.urlShortener.urls.isEmpty)
        n.title="Open"
        check("descriptive informational button renders and accounts its URL",EventStreamNativeNodeRendering.description(n,context:&c)=="button Open, URL: example.test/a?x=1#tail, Help: help alone" && c.urlShortener.urls==[url])
        for role in ["AXCheckBox","AXMenuButton"] {
            n=node(role,"control");n.url=url;c=context(.informationalContext)
            check("informational \(role) shares descriptive gate",EventStreamNativeNodeRendering.description(n,context:&c)=="control" && c.urlShortener.urls.isEmpty)
        }
        n=node("AXGroup","group");n.url=url;c=context(.informationalContext)
        check("informational group still renders URL without descriptive fields",EventStreamNativeNodeRendering.description(n,context:&c)=="container example.test/a?x=1#tail" && c.urlShortener.urls==[url])
        n=node("AXCheckBox","checkbox");n.value="true";n.capturedValueIsBooleanConvertible=true;n.valueTypeName="bool";n.isValueSettable=true;c=context()
        check("rendered value uses value witness rather than stringValue",EventStreamNativeNodeRendering.description(n,context:&c)=="checkbox (settable, bool) true" && n.stringValue==nil)
        n=node("AXTextField","text field");n.placeholderValue="Type";n.identifier="NSField";n.actionDescriptions=[.init(name:"AXPress",description:"Press"),.init(name:"AXDelete",description:"Delete")]
        check("native binding retains placeholder and secondary-action policy",EventStreamNativeNodeRendering.description(n,context:&c)=="text field Placeholder: Type, Secondary Actions: Delete")

        let parent=node("AXGroup","group"),child=node("AXGroup","group")
        var leaf=node("AXStaticText","text");leaf.value="kept"
        typealias Item=EventStreamCollectedItem<EventStreamAXNode>
        let grandchild=Item(node:leaf,path:[0,0],children:[],childrenSubset:nil)
        let middle=Item(node:child,path:[0],children:[grandchild],childrenSubset:nil)
        let root=Item(node:parent,path:[],children:[middle],childrenSubset:nil)
        c=context()
        let transformed=try EventStreamNativeTreeTransformation.transform(.init(roots:[root]),using:[.shared(.flattenRedundantHierarchy)],context:&c)
        check("whole-tree default renderer removes redundant native hierarchy",transformed.preorder.count==2 && transformed.roots[0].children[0].node.value=="kept")
        let contextual=try EventStreamNativeTreeTransformation.transform(.init(roots:[root]),type:.fullUIContext,application:nil,window:nil,using:[.shared(.flattenRedundantHierarchy)])
        check("context-creating entry binds native renderer by default",contextual.tree.preorder.count==2 && contextual.context.urlShortener.urls.isEmpty)
        let overridden=try EventStreamNativeTreeTransformation.transform(.init(roots:[root]),using:[.shared(.flattenRedundantHierarchy)],context:&c) {node,_ in node.element === parent.element ? "parent":"other"}
        check("explicit renderer remains available for owner injection",overridden.preorder.count==3)
        print("EVENT STREAM NATIVE RENDERER: \(checks) checks passed")
    }
}
