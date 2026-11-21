import Foundation
import ApplicationServices

@main enum SelectionMetadataTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let app=EventStreamAXNode(AXUIElementCreateApplication(40000))
        let axWindow=EventStreamAXNode(AXUIElementCreateApplication(40001),supportedAttributes:["AXTitle"],attributes:["AXTitle":"captured AX" as NSString],attributeReader:{_ in fatalError("metadata must not issue a fresh AX read")})
        var events:[String]=[],liveName:String?="Live App",securePID:Int?=123,bundle:String?="com.example.app",cachedTitle:String?="captured AX"
        var bundleSequence:[String?]=[],titleSequence:[String?]=[]
        let nativeCache=EventStreamSelectionMetadataIO.native.cachedWindowTitle
        var io=EventStreamSelectionMetadataIO(runningApplicationName:{pid in events.append("name\(pid)");return liveName},secureInputPID:{events.append("secure");return securePID},runningApplicationBundleIdentifier:{pid in
            events.append("bundle\(pid)");return bundleSequence.isEmpty ? bundle:bundleSequence.removeFirst()
        },desktopIconLevel:{events.append("desktopLevel");return -200},cachedWindowTitle:{_ in
            events.append("cachedTitle");return titleSequence.isEmpty ? cachedTitle:titleSequence.removeFirst()
        })
        func window(title:String?="CG title",owner:String?="CG owner",pid:Int32=123,id:UInt32=42,level:Int=0,node:EventStreamAXNode?=nil)->EventStreamNativeSelectionWindow {
            .init(application:app,window:node ?? axWindow,nativeWindow:.init(id:id,processIdentifier:pid,frame:.zero,level:level,title:title,ownerName:owner))
        }
        func snapshot(title:String?="CG title",owner:String?="CG owner",pid:Int32=123,id:UInt32=42,level:Int=0,url:URL?=nil)->EventStreamSelectionMetadata.Snapshot {
            EventStreamSelectionMetadata.snapshot(window:window(title:title,owner:owner,pid:pid,id:id,level:level),url:url,io:io)
        }
        let first=snapshot(url:URL(string:"https://example.test/page?q=1#part"))
        check("app name prefers live name and preserves selected CG owner identity",first.app.name=="Live App" && first.app.processIdentifier==123)
        check("secure input is attributed only to selected owner PID",first.app.secureInput && first.app.bundleIdentifier=="com.example.app")
        check("recorder cached AX title takes precedence over present CG title",first.window.title=="captured AX" && first.window.windowID==42)
        check("captured URL preserves absolute string query and fragment",first.window.url=="https://example.test/page?q=1#part")
        check("metadata read order evaluates app and fallback before cached title",events==["name123","secure","bundle123","cachedTitle"])
        liveName=nil
        check("missing live name falls back to CG owner name",snapshot().app.name=="CG owner")
        liveName=""
        check("existing empty live name does not borrow CG owner name",snapshot().app.name==nil)
        liveName=nil
        let unnamed=snapshot(owner:nil)
        check("missing both names retains a complete app metadata value",unnamed.app.name==nil && unnamed.app.processIdentifier==123 && unnamed.app.bundleIdentifier=="com.example.app" && unnamed.app.secureInput)
        check("empty CG owner fallback is filtered to nil",snapshot(owner:"").app.name==nil)
        liveName=" \n "
        check("whitespace app names are preserved without trimming",snapshot().app.name==" \n ")
        securePID=999
        check("another app holding secure input does not mark selected app",!snapshot().app.secureInput)
        securePID=nil
        check("missing secure-input PID is false",!snapshot().app.secureInput)
        securePID=0
        check("secure-input policy does not add an unobserved positive PID guard",snapshot(pid:0).app.secureInput)
        securePID=123;bundle=""
        check("empty bundle identifier is filtered",snapshot().app.bundleIdentifier==nil)
        bundle=nil
        check("missing running bundle does not prevent app or window output",snapshot().app.bundleIdentifier==nil && snapshot().window.windowID==42)
        bundle=" \t "
        check("whitespace bundle identifier is preserved",snapshot().app.bundleIdentifier==" \t ")
        bundle="com.example.app";cachedTitle=nil;events=[]
        let cg=snapshot()
        check("absent cached AX title falls back to captured CG title",cg.window.title=="CG title")
        check("present nonempty CG fallback avoids desktop checks",!events.contains("desktopLevel") && events.filter {$0=="cachedTitle"}.count==1)
        cachedTitle=""
        check("empty cached AX title falls back to nonempty CG title",snapshot().window.title=="CG title")
        cachedTitle=" \n "
        check("whitespace cached AX title remains preferred",snapshot().window.title==" \n ")
        cachedTitle="cached-only";events=[]
        check("ApplicationWindow absent CG title uses only its cached title",EventStreamSelectionMetadata.applicationWindowTitle(window(title:nil),io:io)=="cached-only" && events==["cachedTitle"])
        events=[]
        check("ApplicationWindow present empty CG title suppresses its cached fallback",EventStreamSelectionMetadata.applicationWindowTitle(window(title:""),io:io)=="" && events==["desktopLevel"])
        events=[]
        check("recorder still consults cached title after empty CG fallback",snapshot(title:"").window.title=="cached-only" && events.suffix(2)==["desktopLevel","cachedTitle"])
        cachedTitle=nil;events=[]
        check("both titles absent yield nil without fresh attribute access",snapshot(title:nil).window.title==nil && events.filter {$0=="cachedTitle"}.count==2)
        cachedTitle="";events=[]
        check("both titles empty yield nil",snapshot(title:"").window.title==nil)
        bundle="com.apple.finder";cachedTitle=nil;events=[]
        check("Finder desktop-icon-level missing title becomes Desktop",snapshot(title:nil,level:-200).window.title=="Desktop")
        check("desktop Finder title performs independent later bundle lookup",events==["name123","secure","bundle123","cachedTitle","desktopLevel","bundle123","cachedTitle"])
        events=[]
        check("Finder different level does not receive Desktop fallback",snapshot(title:nil,level:-201).window.title==nil && events.filter {$0=="bundle123"}.count==1)
        bundle="com.apple.Finder"
        check("Finder bundle match is exact and case-sensitive",snapshot(title:nil,level:-200).window.title==nil)
        bundle="com.example.app"
        check("desktop icon level alone does not imply Finder",snapshot(title:nil,level:-200).window.title==nil)
        bundleSequence=["com.example.first","com.apple.finder"];cachedTitle=nil
        let independent=snapshot(title:nil,level:-200)
        check("app bundle and Desktop decision use independent samples",independent.app.bundleIdentifier=="com.example.first" && independent.window.title=="Desktop")
        bundle="com.apple.finder";cachedTitle="cached finder"
        check("nonempty cached title overrides Finder Desktop fallback",snapshot(title:"",level:-200).window.title=="cached finder")
        cachedTitle=nil
        check("nonempty CG title prevents Desktop substitution",snapshot(title:"Finder CG",level:-200).window.title=="Finder CG")
        titleSequence=["earlier cache","later cache"];events=[]
        let twice=snapshot(title:nil)
        check("fallback and recorder getter remain separately sampled",twice.window.title=="later cache" && events.filter {$0=="cachedTitle"}.count==2)
        titleSequence=["earlier cache",nil]
        check("later absent cached title retains previously evaluated fallback",snapshot(title:nil).window.title=="earlier cache")
        cachedTitle=nil
        check("missing captured URL remains nil",snapshot().window.url==nil)
        let relative=URL(string:"../other?q=2",relativeTo:URL(string:"https://example.test/folder/base"))!
        check("relative captured URL is serialized as its absolute string",snapshot(url:relative).window.url=="https://example.test/other?q=2")
        check("metadata preserves zero window ID without inventing validation",snapshot(id:0).window.windowID==0)
        let before=axWindow.cachedAttributesSnapshot()
        io.cachedWindowTitle=nativeCache
        let fromNative=EventStreamSelectionMetadata.snapshot(window:window(),url:nil,io:io)
        check("native cache adapter reads captured title without fresh AX",fromNative.window.title=="captured AX")
        check("metadata does not mutate the selected window snapshot",NSDictionary(dictionary:before).isEqual(to:axWindow.cachedAttributesSnapshot()))
        let wrong=EventStreamAXNode(AXUIElementCreateApplication(40003),supportedAttributes:["AXTitle"],attributes:["AXTitle":NSNumber(value:17)],attributeReader:{_ in fatalError("wrong type must not trigger fresh metadata read")})
        check("native malformed cached title uses CG fallback without fresh read",EventStreamSelectionMetadata.snapshot(window:window(node:wrong),url:nil,io:io).window.title=="CG title")
        func prefetch(_ bundle:String?,_ config:[String:Any]=[:])->Bool {EventStreamRecorderPrefetchPolicy.enabled(bundleIdentifier:bundle,configuration:config)}
        check("prefetch defaults to enabled for missing configuration",prefetch("com.example.app"))
        check("explicit false disables prefetch even without bundle identity",!prefetch(nil,["ax_prefetch_enabled":false]))
        check("explicit true retains prefetch without a blocked prefix",prefetch("com.example.app",["ax_prefetch_enabled":true]))
        check("malformed boolean string does not become explicit false",prefetch("com.example.app",["ax_prefetch_enabled":"false"]))
        check("missing bundle skips otherwise matching blocked prefixes",prefetch(nil,["ax_prefetch_disabled_bundle_ids":["com."]]))
        check("blocked bundle comparison is a prefix",!prefetch("com.example.app",["ax_prefetch_disabled_bundle_ids":["com.example"]]))
        check("blocked prefixes are trimmed for whitespace and newlines",!prefetch("com.example.app",["ax_prefetch_disabled_bundle_ids":[" \ncom.example\t"]]))
        check("empty and whitespace prefixes do not block everything",prefetch("com.example.app",["ax_prefetch_disabled_bundle_ids":[""," \n\t"]]))
        check("prefetch bundle comparison preserves case",prefetch("COM.example.app",["ax_prefetch_disabled_bundle_ids":["com.example"]]))
        check("unrelated prefix does not disable prefetch",prefetch("org.example.app",["ax_prefetch_disabled_bundle_ids":["com.example"]]))
        check("one matching later blocked prefix disables prefetch",!prefetch("com.example.app",["ax_prefetch_disabled_bundle_ids":["org.","com."]]))
        check("malformed whole blocked-prefix array is ignored",prefetch("com.example.app",["ax_prefetch_disabled_bundle_ids":[17,"com."] as [Any]]))
        check("single blocked-prefix string is not treated as an array",prefetch("com.example.app",["ax_prefetch_disabled_bundle_ids":"com."]))
        check("explicit true does not override a blocked prefix",!prefetch("com.example.app",["ax_prefetch_enabled":true,"ax_prefetch_disabled_bundle_ids":["com."]]))
        check("empty bundle does not match a nonempty trimmed prefix",prefetch("",["ax_prefetch_disabled_bundle_ids":["com.",""]]))
        check("Swift canonical Unicode prefix equality is retained",!prefetch("com.cafe\u{301}.app",["ax_prefetch_disabled_bundle_ids":["com.café"]]))

        let fixedApp=EventStreamApp(name:"captured",secureInput:false,processIdentifier:123,bundleIdentifier:nil)
        let fixedWindow=EventStreamWindow(title:"captured",url:nil,windowID:42)
        var deferredReads=0
        let deferred=EventStreamAXTreeCapture(revision:1,windowID:42,metadata:{deferredReads += 1;return .init(app:fixedApp,window:fixedWindow)})
        check("deferred metadata is not sampled during snapshot construction",deferredReads==0)
        check("deferred app and window share one metadata sample",deferred.app==fixedApp && deferred.window==fixedWindow && deferredReads==1)
        _=deferred.resolveMetadata();_=deferred.resolveMetadata()
        check("later metadata accesses reuse the resolved snapshot",deferredReads==1)
        let legacy=EventStreamAXTreeCapture(revision:2,windowID:42,app:fixedApp,window:fixedWindow)
        check("existing captured metadata initializer preserves values",legacy.app==fixedApp && legacy.window==fixedWindow)
        let contextOwner=EventStreamNativeContext(),resolver=contextOwner.resolver
        let oldURL=URL(string:"https://old.example")!,newURL=URL(string:"https://new.example")!
        resolver.recordCapturedURL(oldURL,for:42)
        var trace:[String]=[],seenPrevious:[Int?]=[],windowID:UInt32=42,rawURL:URL?=newURL
        var fail=false,metadataReads=0,committedBeforeMetadata=true,urlBeforeRender:URL?
        enum CaptureFailure:Error {case expected}
        var pipeline:EventStreamAXCapture<UInt32,Int>!
        pipeline = .init(resolveContext:{_ in trace.append("resolve");return windowID},contextWindowID:{$0},captureTree:{id,previous in
            trace.append("capture");seenPrevious.append(previous)
            if fail {throw CaptureFailure.expected}
            return .init(revision:(previous ?? 0)+1,windowID:id,metadata:{
                trace.append("metadata");metadataReads += 1
                committedBeforeMetadata = committedBeforeMetadata && pipeline.previousWindowID==id
                resolver.recordCapturedURL(rawURL,for:id)
                return .init(app:fixedApp,window:.init(title:"captured",url:rawURL?.absoluteString,windowID:id))
            })
        },render:{_,_,_,_ in trace.append("render");urlBeforeRender=resolver.windowURLs[windowID];return "tree"})
        let captured=try await pipeline.capture(nil,preferDiff:false)
        check("capture renders before deferred metadata sampling",trace==["resolve","capture","render","metadata"])
        check("predecessor window is committed before live metadata reads",committedBeforeMetadata && pipeline.previousWindowID==42)
        check("URL cache update occurs after rendering",urlBeforeRender==oldURL && resolver.windowURLs[42]==newURL)
        check("result uses the post-render metadata snapshot",captured.app==fixedApp && captured.window?.url==newURL.absoluteString && metadataReads==1)
        trace=[];_=try await pipeline.capture(nil,preferDiff:true)
        check("deferred metadata preserves same-window revision continuation",seenPrevious.count==2 && seenPrevious[0]==nil && seenPrevious[1]==1 && metadataReads==2)
        fail=true;windowID=69;trace=[]
        do {_=try await pipeline.capture(nil,preferDiff:true);fatalError("must throw")} catch CaptureFailure.expected {}
        check("capture error performs neither render metadata nor baseline commit",trace==["resolve","capture"] && metadataReads==2 && pipeline.previousWindowID==42 && resolver.windowURLs[42]==newURL && resolver.windowURLs[69]==nil)
        fail=false;windowID=42;rawURL=nil;trace=[]
        _=try await pipeline.capture(nil,preferDiff:true)
        check("failed other-window capture leaves prior revision available",seenPrevious.last! == 2)
        check("successful nil captured URL removes obsolete cache entry after render",urlBeforeRender==newURL && resolver.windowURLs[42]==nil)
        print("EVENT STREAM SELECTION METADATA: \(checks) checks passed")
    }
}
