import AppKit
import ApplicationServices
import WebKit

private final class AttributedFixturePanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

@MainActor final class AttributedFixtureNavigation:NSObject,WKNavigationDelegate {
    var completed=false
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {completed=true}
}
@main @MainActor enum AttributedNativeTests {
    static var checks=0,failures=0
    static func check(_ name:String,_ condition:@autoclosure ()->Bool) {
        if condition() {checks += 1;print("PASS: \(name)")}
        else {failures += 1;print("FAIL: \(name)")}
    }
    static func fixture() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=AttributedFixturePanel(contentRect:.init(x:100,y:100,width:640,height:560),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
        window.hidesOnDeactivate=false
        window.title="Disposable native attributed text";window.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:.init(x:20,y:280,width:600,height:240))
        let text=NSTextView(frame:scroll.bounds);text.isEditable=true;text.isRichText=true
        text.setAccessibilityIdentifier("attributed-text-area")
        let value=NSMutableAttributedString(string:"Bold plain\nItalic underline\nLink\n😀 end",attributes:[.font:NSFont.systemFont(ofSize:14)])
        let raw=value.string as NSString
        value.addAttribute(.font,value:NSFont.boldSystemFont(ofSize:14),range:raw.range(of:"Bold"))
        value.addAttribute(.font,value:NSFontManager.shared.convert(NSFont.systemFont(ofSize:14),toHaveTrait:.italicFontMask),range:raw.range(of:"Italic"))
        value.addAttribute(.underlineStyle,value:1,range:raw.range(of:"underline"))
        value.addAttribute(.link,value:URL(string:"https://example.com/native-link")!,range:raw.range(of:"Link"))
        text.textStorage!.setAttributedString(value);scroll.documentView=text;window.contentView!.addSubview(scroll)
        let web=WKWebView(frame:.init(x:20,y:20,width:600,height:220));web.setAccessibilityIdentifier("attributed-web-view")
        let navigation=AttributedFixtureNavigation();web.navigationDelegate=navigation
        window.contentView!.addSubview(web)
        web.loadHTMLString("<html><body><h1>Web title</h1><p><b>Web bold</b> tail <a href='https://example.com/web-link'>Web link</a></p><p>Web end</p></body></html>",baseURL:nil)
        window.orderBack(nil);app.finishLaunching()
        let timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) {timer in
            MainActor.assumeIsolated {
                guard navigation.completed else {return};timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    let data=try! JSONSerialization.data(withJSONObject:["pid":getpid(),"window":window.windowNumber,"isKeyWindow":window.isKeyWindow]);FileHandle.standardOutput.write(data+Data([10]))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+45) {app.terminate(nil)}
        withExtendedLifetime((window,text,scroll,web,navigation,timer)) {app.run()}
    }
    static func main() throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--fixture") {fixture();return}
        guard AXIsProcessTrusted(),(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {throw NSError(domain:"AttributedNativeTestsSession",code:1)}
        let child=Process(),pipe=Pipe();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--fixture"];child.standardOutput=pipe;child.standardError=FileHandle.standardError
        try child.run()
        let watchdog=DispatchWorkItem {if child.isRunning {child.terminate()}};DispatchQueue.global().asyncAfter(deadline:.now()+25,execute:watchdog)
        defer {watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit()}
        var ready=Data()
        while !ready.contains(10) {let next=pipe.fileHandleForReading.availableData;guard !next.isEmpty else {throw NSError(domain:"AttributedNativeTestsReady",code:1)};ready.append(next)}
        let object=try JSONSerialization.jsonObject(with:ready.prefix { $0 != 10 }) as! [String:Any]
        let pid=(object["pid"] as! NSNumber).int32Value
        guard object["isKeyWindow"] as? Bool == false else {throw NSError(domain:"AttributedNativeTestsReadiness",code:1)}
        func raw(_ e:AXUIElement,_ key:String)->AnyObject? {var v:CFTypeRef?;_ = AXUIElementCopyAttributeValue(e,key as CFString,&v);return v}
        func children(_ e:AXUIElement)->[AXUIElement] {
            ((raw(e,"AXChildren") as? [AnyObject]) ?? []).compactMap {CFGetTypeID($0)==AXUIElementGetTypeID() ? unsafeBitCast($0,to:AXUIElement.self):nil}
        }
        let app=AXUIElementCreateApplication(pid);var queue=[app],position=0,area:AXUIElement?,web:AXUIElement?
        while position<queue.count && position<250 {
            let e=queue[position];position += 1
            let role=raw(e,"AXRole") as? String
            if role=="AXTextArea",raw(e,"AXValue") as? String == "Bold plain\nItalic underline\nLink\n😀 end" {area=e}
            if role=="AXWebArea" {web=e}
            queue += children(e)
        }
        if web==nil || area==nil {
            let deadline=Date().addingTimeInterval(5)
            while (web==nil || area==nil) && Date()<deadline {
                Thread.sleep(forTimeInterval:0.05);queue=[app];position=0
                while position<queue.count && position<250 {
                    let e=queue[position];position += 1
                    let role=raw(e,"AXRole") as? String
                    if role=="AXWebArea" {web=e}
                    if role=="AXTextArea",raw(e,"AXIdentifier") as? String == "attributed-text-area",
                       raw(e,"AXValue") as? String == "Bold plain\nItalic underline\nLink\n😀 end" {area=e}
                    queue += children(e)
                }
            }
        }
        check("owned native rich-text area is discoverable",area != nil)
        check("owned WebKit web area is discoverable",web != nil)
        guard let area else {throw NSError(domain:"AttributedNativeTestsElements",code:1)}
        let snapshots=EventStreamNativeSnapshots(),backend=EventStreamNativeAttributedTextBackend()
        let node=EventStreamNativeNode.construct(snapshots.node(area),context:.init(kind:1))
        let acquired=try EventStreamAttributedTextAcquisition.acquire(node,pass:.retrieveAttributedTextFromTextAreas,type:.eventStreamContext,backend:backend)
        check("actual NSTextView returns an attributed AX range",acquired != nil && acquired!.string==node.value)
        guard let acquired else {throw NSError(domain:"AttributedNativeTestsText",code:1)}
        print("NOTE: native attributed source length=\(acquired.length)")
        let windowReference=((raw(app,"AXWindows") as? [AnyObject]) ?? []).first {CFGetTypeID($0)==AXUIElementGetTypeID()}.map {unsafeBitCast($0,to:AXUIElement.self)}
        guard let windowReference else {throw NSError(domain:"AttributedNativeTestsWindow",code:1)}
        let applicationSource=snapshots.node(app),windowSource=snapshots.node(windowReference)
        var context=EventStreamNativeTransformationContext.make(type:.eventStreamContext,application:applicationSource,window:windowSource)
        check("actual attributed fixture uses native app/window context and URL defaults",context.type == .eventStreamContext && context.windowFrame != nil && context.urlShortener.configuration == .init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
        let rich=EventStreamNativeAttributedMarkdown().format(acquired,context:&context)
        print("DIAGNOSTIC rich text markdown: \(String(reflecting:rich.description))")
        check("native AX font metadata formats bold",rich.description.contains("**Bold**"))
        check("native AX font metadata formats italic",rich.description.contains("*Italic*"))
        check("native AX underline metadata formats underline",rich.description.contains("<u>underline</u>"))
        check("native NSTextView link uses actual captured AX element URL",rich.description.contains("[Link](example.com/native-link)") && context.urlShortener.urls.contains(URL(string:"https://example.com/native-link")!))
        var truncated=node;truncated.truncationRange=(node.value! as NSString).range(of:"Italic")
        let part=try EventStreamAttributedTextAcquisition.acquire(truncated,pass:.retrieveAttributedTextFromTextAreas,type:.eventStreamContext,backend:backend)
        check("native explicit AX range returns only requested source text",part?.string=="Italic")
        if let part {
            let partial=EventStreamNativeAttributedMarkdown().format(part,context:&context)
            check("native partial range maps the acquired substring from zero",partial.description=="*Italic*" && partial.sourceOffsets==[nil,0,1,2,3,4,5,nil])
        }
        let textChildren=children(area).enumerated().map {index,element in
            EventStreamCollectedItem(node:EventStreamNativeNode.construct(snapshots.node(element),context:.init(kind:1)),path:[2,index],children:[],childrenSubset:nil)
        }
        check("native text-area fixture has an actual AX link child",textChildren.contains {$0.node.role=="AXLink"})
        let item=EventStreamCollectedItem(node:node,path:[2],children:textChildren,childrenSubset:nil)
        let transformed=try EventStreamMacTreeTransform.transformAttributed(item,pass:.retrieveAttributedTextFromTextAreas,context:&context,backend:.init(),attributed:backend,formatter:.init()) {_,_ in preconditionFailure("must not render")}
        if case .transformed(let output)=transformed {
            check("native Mac text-area entry formats actual external AX text",output.node.value==rich.description && output.node.transformedString?.sourceOffsets==rich.sourceOffsets && output.node.attributedString?.string==node.value && output.path==[2])
            check("native Mac text-area entry retains actual loaded link children",output.children.count==textChildren.count && zip(output.children,textChildren).allSatisfy {CFEqual($0.node.element.element,$1.node.element.element)})
        } else {check("native Mac text-area entry formats actual external AX text",false)}
        let wholeTextTree=try EventStreamNativeTreeTransformation.transform(.init(roots:[item]),context:&context) {_,_ in
            preconditionFailure("descriptive text/links do not require a renderer")
        }
        check("full native tree pipeline formats real external NSTextView",wholeTextTree.roots.first?.node.value==rich.description && wholeTextTree.roots.first?.node.transformedString?.sourceOffsets==rich.sourceOffsets)
        if let output=wholeTextTree.roots.first {
            let rendered=EventStreamNativeNodeRendering.description(output.node,context:&context)
            check("native renderer includes actual formatted NSTextView Markdown",rendered.contains("**Bold**") && rendered.contains("[Link](example.com/native-link)"))
        } else {check("native renderer includes actual formatted NSTextView Markdown",false)}
        var retrimmedText=wholeTextTree
        var retrimContext=EventStreamMacTransformationContext(type:.eventStreamContext,
            urlShortener:.init(configuration:.init(individualLimit:10,totalLimit:nil,includeQuery:true,includeFragment:true)))
        EventStreamTreeURLTrimming.trim(&retrimmedText,context:&retrimContext)
        check("native tree URL retrim preserves literal mapped NSTextView Markdown",retrimmedText.roots.first?.node.value==rich.description && retrimmedText.roots.first?.node.transformedString?.spans.allSatisfy {if case .string(_) = $0 {return true};return false}==true && retrimmedText.roots.first?.node.transformedString?.sourceOffsets==wholeTextTree.roots.first?.node.transformedString?.sourceOffsets)
        check("native rich output map matches displayed UTF16 length",rich.sourceOffsets?.count==rich.description.utf16.count)
        check("native rich text surrogate positions are retained",rich.sourceOffsets?.compactMap {$0}.contains((node.value! as NSString).range(of:"😀").location)==true)
        guard let web else {throw NSError(domain:"AttributedNativeTestsWebArea",code:1)}
        let nativeWeb=snapshots.node(web)
        let start=backend.marker(EventStreamAttributedTextAttributes.startMarker,of:nativeWeb),end=backend.marker(EventStreamAttributedTextAttributes.endMarker,of:nativeWeb)
        check("actual WebKit exposes valid typed start and end markers",start != nil && end != nil)
        if let start,let end {
            let range=try backend.makeMarkerRange(start:start,end:end)
            check("native SPI creates a valid marker range",range.map {EventStreamTextMarkerSPI.isRange($0)}==true)
            if let range {
                let options=backend.parameterizedAttributes(nativeWeb).contains(EventStreamAttributedTextAttributes.attributedMarkerRangeWithOptions)
                let direct=try backend.attributedString(range,of:nativeWeb,withOptions:options)
                check("actual WebKit marker range returns attributed content",direct?.string.contains("Web bold")==true && direct?.string.contains("Web end")==true)
            }
        }
        let webNode=EventStreamNativeNode.construct(nativeWeb,context:.init(kind:2))
        check("native WebKit snapshot keeps actual AXWebArea role",webNode.role=="AXWebArea")
        let webText=try EventStreamAttributedTextAcquisition.acquire(webNode,pass:.retrieveAttributedTextFromWebAreas,type:.informationalContext,backend:backend)
        check("web acquisition consumes live marker range",webText?.string.contains("Web bold")==true && webText?.string.contains("Web end")==true)
        if let webText {
            let formatted=EventStreamNativeAttributedMarkdown().format(webText,context:&context)
            print("DIAGNOSTIC WebKit markdown: \(String(reflecting:formatted.description))")
            check("live WebKit preserves continuous bold from title through bold text",formatted.description.hasPrefix("**Web title") && formatted.description.contains("Web bold** tail"))
            check("live WebKit links use actual AX link element metadata",formatted.description.contains("[Web link](example.com/web-link)"))
            check("live WebKit UTF16 map matches formatted length",formatted.sourceOffsets?.count==formatted.description.utf16.count)
            context.type = .informationalContext
            let webChildren=children(web).enumerated().map {index,element in
                EventStreamCollectedItem(node:EventStreamNativeNode.construct(snapshots.node(element),context:.init(kind:2)),path:[3,index],children:[],childrenSubset:nil)
            }
            check("native WebKit fixture has real loaded DOM children",!webChildren.isEmpty)
            let webItem=EventStreamCollectedItem(node:webNode,path:[3],children:webChildren,childrenSubset:nil)
            let result=try EventStreamMacTreeTransform.transformAttributed(webItem,pass:.retrieveAttributedTextFromWebAreas,context:&context,backend:.init(),attributed:backend,formatter:.init()) {_,_ in preconditionFailure("must not render")}
            if case .transformed(let output)=result {
                check("native Mac web entry consumes real markers and clears loaded children",output.node.value==formatted.description && output.children.isEmpty && output.node.attributedString?.string==webText.string && output.path==[3])
            } else {check("native Mac web entry consumes real markers and clears loaded children",false)}
            let wholeWebTree=try EventStreamNativeTreeTransformation.transform(.init(roots:[webItem],focusedElement:node),
                using:[.retrieveAttributedTextFromTextAreas,.retrieveAttributedTextFromWebAreas],context:&context) {_,_ in
                    preconditionFailure("attributed passes do not render")
                }
            check("native tree driver processes real WebKit markers before descending",wholeWebTree.roots.first?.node.value==formatted.description && wholeWebTree.roots.first?.children.isEmpty==true && wholeWebTree.focusedElement.map {CFEqual($0.element.element,area)}==true)
            let contextual=try EventStreamNativeTreeTransformation.transform(.init(roots:[webItem]),type:.informationalContext,
                application:applicationSource,window:windowSource,using:[.retrieveAttributedTextFromWebAreas]) {_,_ in
                    preconditionFailure("attributed pass does not render")
                }
            check("native context-creating entry formats real WebKit marker content",contextual.tree.roots.first?.node.value==formatted.description && contextual.context.windowFrame != nil && contextual.context.urlShortener.urls.contains(URL(string:"https://example.com/web-link")!))
            if let output=contextual.tree.roots.first {
                let rendered=EventStreamNativeNodeRendering.description(output.node,context:&context)
                check("native renderer includes actual WebKit marker Markdown",rendered.contains("Web bold** tail") && rendered.contains("[Web link](example.com/web-link)"))
            } else {check("native renderer includes actual WebKit marker Markdown",false)}
            var retrimmedWeb=contextual.tree
            var webRetrimContext=EventStreamMacTransformationContext(type:.informationalContext,
                urlShortener:.init(configuration:.init(individualLimit:10,totalLimit:nil,includeQuery:true,includeFragment:true)))
            EventStreamTreeURLTrimming.trim(&retrimmedWeb,context:&webRetrimContext)
            check("native informational WebKit retrim preserves literal Markdown without parsing URLs",retrimmedWeb.roots.first?.node.value==formatted.description && retrimmedWeb.roots.first?.node.transformedString?.description==formatted.description && webRetrimContext.urlShortener.urls.isEmpty)
        }
        print("NATIVE ATTRIBUTED TEXT: \(checks) checks passed; \(failures) failed")
        if failures>0 {throw NSError(domain:"AttributedNativeTests",code:failures)}
    }
}
