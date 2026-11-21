import AppKit
import ApplicationServices

@MainActor final class ContextFactoryBackend:EventStreamTransformationContextBackend {
    typealias Element=Int
    var events:[String]=[],web=[false,false],catalyst=false,chrome=false,rectangle:CGRect?
    func isCatalystApp(_ application:Int)->Bool {events.append("catalyst:\(application)");return catalyst}
    func isWebShaped(_ application:Int)->Bool {events.append("web:\(application)");return web.removeFirst()}
    func firstChildHasChromeNodeID(_ window:Int)->Bool {events.append("chrome:\(window)");return chrome}
    func frame(_ window:Int)->CGRect? {events.append("frame:\(window)");return rectangle}
}
@main @MainActor enum TransformationContextTests {
    static var checks=0
    static func check(_ name:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(name)\n",stderr)}
        precondition(okay,name);checks += 1;print("PASS: \(name)")
    }
    static func main() throws {
        setbuf(stdout,nil)
        let b=ContextFactoryBackend(),frame=CGRect(x:3,y:7,width:100,height:40)
        func make(_ app:Int?=nil,_ window:Int?=nil,_ config:EventStreamURLShortener.Configuration?=nil)->EventStreamMacTransformationContext {
            EventStreamTransformationContextFactory.make(type:.informationalContext,application:app,window:window,urlConfiguration:config,backend:b)
        }
        var context=make()
        check("missing application/window perform no reads",b.events.isEmpty && !context.isCatalyst && !context.isWebShaped && !context.isChromium && context.windowFrame==nil)
        check("context type is retained",context.type == .informationalContext)
        check("native nil URL configuration has unlimited limits and includes query/fragment",context.urlShortener.configuration == .init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
        b.rectangle=frame
        context=make(nil,2)
        check("window frame is read even with missing application",b.events==["frame:2"] && context.windowFrame==frame && !context.isChromium)
        b.events=[];b.catalyst=true;b.web=[true,true];b.chrome=true
        context=make(1,2)
        check("native read order retains the second independent web query",b.events==["catalyst:1","web:1","web:1","chrome:2","frame:2"] && context.isCatalyst && context.isWebShaped && context.isChromium)
        b.events=[];b.web=[false,true]
        context=make(1,2)
        check("second web result can enable Chrome probe despite false stored flag",!context.isWebShaped && context.isChromium && b.events.contains("chrome:2"))
        b.events=[];b.web=[true,false]
        context=make(1,2)
        check("second web false skips probe despite true stored flag",context.isWebShaped && !context.isChromium && !b.events.contains("chrome:2"))
        b.events=[];b.web=[true,true]
        context=make(1,nil)
        check("missing window still performs both web queries",b.events==["catalyst:1","web:1","web:1"] && context.windowFrame==nil && !context.isChromium)
        let config=EventStreamURLShortener.Configuration(individualLimit:-2,totalLimit:0,includeQuery:false,includeFragment:false,baseHost:"ignored")
        check("explicit URL configuration is copied without normalization",make(nil,nil,config).urlShortener.configuration==config)
        var one=make(),two=make();let url=URL(string:"https://example.com/path?q=1#fragment")!
        check("default configuration retains native query/fragment display",one.urlShortener.trim(url:url,isImage:false)=="example.com/path?q=1#fragment")
        check("each context starts with independent URL accounting",one.urlShortener.accumulated>0 && two.urlShortener.accumulated==0 && two.urlShortener.urls.isEmpty)
        two.urlShortener.configuration.includeQuery=false
        check("context configuration has value semantics",one.urlShortener.configuration.includeQuery && !two.urlShortener.configuration.includeQuery)
        check("HTTP scheme declaration is recognized",EventStreamBundleShape.supportsHTTP([["CFBundleURLSchemes":["other","http"]]]))
        check("HTTPS alone and case/whitespace variants do not match",!EventStreamBundleShape.supportsHTTP([["CFBundleURLSchemes":["https","HTTP","http "]]]))
        check("URLTypes requires an array of dictionaries",!EventStreamBundleShape.supportsHTTP(["CFBundleURLSchemes":["http"]]))
        check("one malformed URLTypes entry invalidates the typed array",!EventStreamBundleShape.supportsHTTP([["CFBundleURLSchemes":["http"]],"invalid"] as [Any]))
        check("malformed scheme array is ignored while a later valid declaration wins",EventStreamBundleShape.supportsHTTP([["CFBundleURLSchemes":[1,"http"] as [Any]],["CFBundleURLSchemes":["http"]]]))
        check("empty and missing bundle URL metadata return false",!EventStreamBundleShape.supportsHTTP(nil) && !EventStreamBundleShape.supportsHTTP([] as [Any]))
        var reads:[String]=[]
        check("HTTP short-circuits principal-class reads",EventStreamBundleShape.isWebShaped {key in reads.append(key);return [["CFBundleURLSchemes":["http"]]]} && reads==["CFBundleURLTypes"])
        reads=[]
        check("Electron principal class is exact and short-circuits",EventStreamBundleShape.isWebShaped {key in reads.append(key);return key=="NSPrincipalClass" ? "AtomApplication":nil} && reads==["CFBundleURLTypes","NSPrincipalClass"])
        reads=[]
        check("Chromium uses a separate second principal-class read",EventStreamBundleShape.isWebShaped {key in reads.append(key);return key=="NSPrincipalClass" ? "BrowserCrApplication":nil} && reads==["CFBundleURLTypes","NSPrincipalClass","NSPrincipalClass"])
        var principals=["other","BrowserCrApplication"]
        check("principal-class reads are not collapsed to one value",EventStreamBundleShape.isWebShaped {key in key=="NSPrincipalClass" ? principals.removeFirst():nil} && principals.isEmpty)
        for value:Any in ["atomapplication","BrowserCrApplication ",NSNumber(value:true),NSNull()] {
            check("invalid principal class does not infer browser shape \(value)",!EventStreamBundleShape.isWebShaped {key in key=="NSPrincipalClass" ? value:nil})
        }

        let ax=AXUIElementCreateApplication(getpid()),child=AXUIElementCreateApplication(getpid()+1)
        var values:[String:AnyObject]=[:],events:[String]=[],countError=AXError.success,countValue=1
        var array:AnyObject?=[child] as NSArray,capabilities:Set<String>=["ChromeAXNodeId"]
        var pid:pid_t?=42,failPID=false,bundleAvailable=true,info:[String:Any]=["NSPrincipalClass":"BrowserCrApplication"]
        enum Fault:Error {case pid}
        var io=EventStreamNativeTransformationContextIO.native
        io.attribute={_,name in events.append("read:"+name);return values[name]}
        io.arrayCount={_,name in events.append("count:"+name);return (countError,countValue)}
        io.arrayValues={_,name,index,maximum in events.append("array:\(name):\(index):\(maximum)");return array}
        io.supported={element in precondition(CFEqual(element,child));events.append("supported:child");return capabilities}
        io.processIdentifier={_ in events.append("pid");if failPID {throw Fault.pid};return pid}
        io.bundleInfo={actualPID in precondition(actualPID==42);events.append("bundle");guard bundleAvailable else {return nil};return {key in events.append("info:"+key);return info[key]}}
        let backend=EventStreamNativeTransformationContextBackend(io:io),catalyst="_AXExhibitsMacCatalystBehavior"
        let cachedFalse=EventStreamAXNode(ax,supportedAttributes:[],attributes:[catalyst:NSNumber(value:false)],transactionAttributes:[catalyst])
        values[catalyst]=NSNumber(value:true)
        check("native valid cached false wins outside advertised support",!backend.isCatalystApp(cachedFalse) && events.isEmpty)
        let malformed=EventStreamAXNode(ax,supportedAttributes:[catalyst],attributes:[catalyst:NSNull()])
        check("native malformed cached Catalyst value permits typed fresh read",backend.isCatalystApp(malformed) && events==["read:"+catalyst])
        _=backend.isCatalystApp(malformed)
        check("typed fresh Catalyst read does not overwrite captured value",events==["read:"+catalyst,"read:"+catalyst] && malformed.cachedAttribute(catalyst) is NSNull)
        events=[]
        check("requested unsupported Catalyst attribute suppresses native read",!backend.isCatalystApp(EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:[catalyst])) && events.isEmpty)
        check("unrequested Catalyst attribute can read outside prefetch subset",backend.isCatalystApp(EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:["AXRole"])))
        values[catalyst]=NSNumber(value:2);events=[]
        check("native Catalyst decoder uses Bool cast rather than NSNumber.boolValue",!backend.isCatalystApp(EventStreamAXNode(ax)) && events==["read:"+catalyst])
        values[catalyst]="true" as NSString
        check("native Catalyst decoder rejects string booleans",!backend.isCatalystApp(EventStreamAXNode(ax)))
        values[catalyst]=NSNumber(value:1)
        check("native Catalyst decoder accepts NSNumber one",backend.isCatalystApp(EventStreamAXNode(ax)))
        values[catalyst]=nil;events=[]
        check("native absent Catalyst attribute returns false",!backend.isCatalystApp(EventStreamAXNode(ax)))
        events=[]
        check("native Chrome probe counts and requests index0/max1 before supported names",backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)) && events==["count:AXChildren","array:AXChildren:0:1","supported:child"])
        events=[];countError = .cannotComplete
        check("failed native child count prevents array request",!backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)) && events==["count:AXChildren"])
        countError = .success;countValue=0;events=[]
        check("successful zero child count still issues a max-1 request",backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)) && events.count==3)
        countValue=1;events=[];array=[NSNull(),child] as NSArray
        check("malformed returned array members compactMap before first child selection",backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)))
        events=[];array=[NSNull()] as NSArray
        check("no valid child suppresses supported-attribute lookup",!backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)) && events.count==2)
        array=[child] as NSArray;capabilities=["ChromeAXNodeID"]
        check("Chrome attribute spelling is exact",!backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)))
        capabilities=["ChromeAXNodeId"];array=nil
        check("absent child array returns false",!backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)))
        array="wrong" as NSString
        check("nonarray child response returns false",!backend.firstChildHasChromeNodeID(EventStreamAXNode(ax)))
        array=[child] as NSArray;events=[]
        check("Chrome probe ignores parent cached children and requested metadata",backend.firstChildHasChromeNodeID(EventStreamAXNode(ax,supportedAttributes:[],attributes:["AXChildren":[] as NSArray],transactionAttributes:["AXChildren"])) && events.count==3)
        events=[]
        check("native web-shape uses PID, bundle then short-circuit info reads",backend.isWebShaped(EventStreamAXNode(ax)) && events==["pid","bundle","info:CFBundleURLTypes","info:NSPrincipalClass","info:NSPrincipalClass"])
        events=[];pid=nil
        check("missing PID does not borrow current process bundle",!backend.isWebShaped(EventStreamAXNode(ax)) && events==["pid"])
        pid=42;failPID=true;events=[]
        check("PID errors return false without bundle lookup",!backend.isWebShaped(EventStreamAXNode(ax)) && events==["pid"])
        failPID=false;bundleAvailable=false;events=[]
        check("missing bundle returns false",!backend.isWebShaped(EventStreamAXNode(ax)) && events==["pid","bundle"])
        bundleAvailable=true;info=["CFBundleURLTypes":[["CFBundleURLSchemes":["http"]]]];events=[]
        check("native HTTP bundle avoids principal-class queries",backend.isWebShaped(EventStreamAXNode(ax)) && events==["pid","bundle","info:CFBundleURLTypes"])
        var rectangle=frame,point=CGPoint(x:-4,y:6),size=CGSize(width:9,height:12)
        let rectValue=AXValueCreate(.cgRect,&rectangle)!,pointValue=AXValueCreate(.cgPoint,&point)!,sizeValue=AXValueCreate(.cgSize,&size)!
        events=[]
        let cachedRect=EventStreamAXNode(ax,supportedAttributes:[],attributes:["AXFrame":rectValue],transactionAttributes:["AXFrame"])
        check("native cached rectangle wins without fresh reads",backend.frame(cachedRect)==frame && events.isEmpty)
        values=["AXFrame":rectValue];events=[]
        check("native fresh rectangle avoids position and size reads",backend.frame(EventStreamAXNode(ax))==frame && events==["read:AXFrame"])
        values=["AXFrame":NSNull(),"AXPosition":pointValue,"AXSize":sizeValue];events=[]
        check("native invalid frame falls back to position then size",backend.frame(EventStreamAXNode(ax))==CGRect(origin:point,size:size) && events==["read:AXFrame","read:AXPosition","read:AXSize"])
        _=backend.frame(EventStreamAXNode(ax,supportedAttributes:["AXFrame","AXPosition","AXSize"],attributes:["AXFrame":NSNull(),"AXPosition":pointValue,"AXSize":sizeValue]))
        check("cached fallback geometry does not need native position/size reads",events.suffix(1)==["read:AXFrame"])
        values=["AXFrame":pointValue,"AXSize":sizeValue];events=[]
        check("wrong AX geometry type does not decode as frame and missing point skips size",backend.frame(EventStreamAXNode(ax))==nil && events==["read:AXFrame","read:AXPosition"])
        values=["AXFrame":rectValue];events=[]
        let blocked=EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:["AXFrame","AXPosition","AXSize"])
        check("requested unsupported geometry prevents all native reads",backend.frame(blocked)==nil && events.isEmpty)
        let bridged=EventStreamAXNode(ax,attributes:["AXFrame":NSValue(rect:frame)])
        check("native frame decoder supports Objective-C CGRect bridging",backend.frame(bridged)==frame)
        var unusual=CGRect(origin:.init(x:CGFloat.infinity,y:-4),size:.init(width:-5,height:0))
        let unusualValue=AXValueCreate(.cgRect,&unusual)!
        let odd=backend.frame(EventStreamAXNode(ax,attributes:["AXFrame":unusualValue]))
        check("native geometry is not clamped or finite-filtered",odd?.origin.x.isInfinite==true && odd?.size.width == -5 && odd?.size.height==0)
        values=["AXFrame":NSNull(),"AXPosition":NSValue(point:point),"AXSize":NSValue(size:size)]
        check("native position and size support Objective-C bridging",backend.frame(EventStreamAXNode(ax))==CGRect(origin:point,size:size))
        let output=try EventStreamNativeTreeTransformation.transform(.init(roots:[]),type:.eventStreamContext,application:nil,window:cachedRect,contextBackend:backend,using:[]) {_,_ in preconditionFailure("empty tree")}
        check("native context-creating tree entry returns transformed tree and actual frame",output.tree.roots.isEmpty && output.context.windowFrame==frame && output.context.type == .eventStreamContext)
        check("native context-creating entry keeps the default URL settings",output.context.urlShortener.configuration == .init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
        print("Event-stream transformation context: \(checks) checks passed")
    }
}
