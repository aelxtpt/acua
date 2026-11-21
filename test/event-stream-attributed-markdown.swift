import AppKit
import ApplicationServices

@main @MainActor enum AttributedMarkdownTests {
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func shortener()->EventStreamURLShortener {
        .init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
    }
    static func format(_ text:String,_ attrs:[NSAttributedString.Key:Any]=[:])->EventStreamTransformedString {
        var s=shortener()
        return EventStreamAttributedMarkdown.format(NSAttributedString(string:text,attributes:attrs),shortener:&s) {_ in preconditionFailure("unexpected element")}
    }
    static func joined(_ runs:[(String,[NSAttributedString.Key:Any])])->EventStreamTransformedString {
        let text=NSMutableAttributedString(string:"")
        for (string,attrs) in runs {text.append(NSAttributedString(string:string,attributes:attrs))}
        var s=shortener()
        return EventStreamAttributedMarkdown.format(text,shortener:&s) {_ in preconditionFailure("unexpected element")}
    }
    static func main() {
        setbuf(stdout,nil)
        // Trap paths use a disposable child executable, never the service.
        if CommandLine.arguments.contains("--multi-scalar-attachment") {
            var s=shortener()
            _=EventStreamAttributedMarkdown.format(NSAttributedString(string:"e\u{301}",attributes:[.accessibilityAttachment:"fake"]),shortener:&s) {_ in .init(role:"AXGroup",url:nil,description:nil,roleDescription:nil)}
            return
        }
        let plain=format("é😀e\u{301}")
        check("plain text preserves UTF16 spelling",Array(plain.description.utf16)==Array("é😀e\u{301}".utf16))
        check("source positions count UTF16 units",plain.sourceOffsets==[0,1,2,3,4])
        check("empty attributed input flushes a present empty map",format("").sourceOffsets==[] && format("").spans == [.string("")])
        check("plain Markdown punctuation remains unescaped",format("[a]*_`<x>").description=="[a]*_`<x>")
        let bold:[NSAttributedString.Key:Any]=[.accessibilityFont:["AXFontBold":true]]
        let under:[NSAttributedString.Key:Any]=[.accessibilityUnderline:1]
        let strike:[NSAttributedString.Key:Any]=[.accessibilityStrikethrough:1]
        check("explicit font bold survives missing font name and size",format("a",bold).description=="**a**")
        check("font bold false adds no style",format("a",[.accessibilityFont:["AXFontBold":false]]).description=="a")
        check("malformed font dictionary is ignored",format("a",[.accessibilityFont:"bold"]).description=="a")
        check("ordinary AppKit font key is not AXFont",format("a",[.font:NSFont.boldSystemFont(ofSize:12)]).description=="a")
        check("font descriptor infers bold",format("a",[.accessibilityFont:[NSAccessibility.FontAttributeKey.fontName.rawValue:"Helvetica-Bold",NSAccessibility.FontAttributeKey.fontSize.rawValue:12.0]]).description=="**a**")
        check("font descriptor infers italic",format("a",[.accessibilityFont:[NSAccessibility.FontAttributeKey.fontName.rawValue:"Helvetica-Oblique",NSAccessibility.FontAttributeKey.fontSize.rawValue:12.0]]).description=="*a*")
        check("font name alone does not infer traits",format("a",[.accessibilityFont:[NSAccessibility.FontAttributeKey.fontName.rawValue:"Helvetica-Bold"]]).description=="a")
        check("underline positive integer",format("a",under).description=="<u>a</u>")
        check("underline zero and negatives ignored",format("a",[.accessibilityUnderline:0]).description=="a" && format("a",[.accessibilityUnderline:-1]).description=="a")
        check("strikethrough uses NSNumber boolValue",format("a",strike).description=="~~a~~" && format("a",[.accessibilityStrikethrough:0]).description=="a")
        check("superscript sign selects tag",format("a",[.accessibilitySuperscript:7]).description=="<sup>a</sup>" && format("a",[.accessibilitySuperscript:-2]).description=="<sub>a</sub>" && format("a",[.accessibilitySuperscript:0]).description=="a")
        var both=bold;both.merge(under) {a,_ in a}
        check("closing styles retain original forward order",format("a",both).description=="**<u>a**</u>")
        check("common bold stays open across underline transition",joined([("a",bold),("b",both),("c",bold)]).description=="**a<u>b</u>c**")
        check("removing older style does not close common newer style",joined([("a",both),("b",under)]).description=="**<u>a**b</u>")
        let marked=format("😀",bold)
        check("syntax is unmapped while label retains absolute UTF16 positions",marked.sourceOffsets==[nil,nil,0,1,nil,nil])
        let key=NSAttributedString.Key("AXStyleName"),quote=NSAttributedString.Key("AXBlockQuoteLevel")
        for (name,prefix) in [("Title","# "),("Heading","## "),("Subheading","### ")] {
            check("style \(name) selects heading level",format("x",[key:name]).description==prefix+"x")
        }
        check("style names split only comma-space",format("x",[key:"Title, Heading"]).description=="## # x" && format("x",[key:"Title,Heading"]).description=="x")
        check("duplicate style names are deduplicated",format("x",[key:"Title, Title"]).description=="# x")
        check("inactive style names and unknown names do not add wrappers",format("x",[key:"Body, Contains paragraphs, Expanded, Unknown"]).description=="x")
        check("code block has exact fence and final flush",format("x",[key:"Fixed width"]).description=="```\nx\n```")
        check("collapsed has exact literal closing message",format("x",[key:"Collapsed"]).description=="<details><summary>\nx\n</summary>(collapsed content is hidden)</details>")
        check("quote prefixes use repeated greater-than without extra spaces",format("x",[quote:2]).description==">> x")
        check("nonpositive quotes ignored",format("x",[quote:0]).description=="x" && format("x",[quote:-1]).description=="x")
        check("structural styles prepend ahead of inline styles",format("x",both.merging([key:"Title",quote:2]) {a,_ in a}).description=="# >> **<u>x**</u>")
        func list(_ prefix:String,level:Int=0,index:NSNumber=4)->[NSAttributedString.Key:Any] {
            [.accessibilityListItemPrefix:NSAttributedString(string:prefix),.accessibilityListItemLevel:level,.accessibilityListItemIndex:index]
        }
        check("unordered prefix collapses to asterisk",format("x",list("•")).description=="* x")
        check("ordered prefix uses index rather than prefix digits",format("x",list("999.")).description=="4. x")
        check("number detection uses first Character and supports non-ASCII numbers",format("x",list("Ⅻ")).description=="4. x" && format("x",list(" 1.")).description=="* x")
        check("ordered number uses NSNumber stringValue",format("x",list("1.",index:4.5)).description=="4.5. x")
        check("nested lists indent four spaces per level",format("x",list("*",level:2)).description=="        * x")
        check("empty prefix is unordered",format("x",list("")).description=="* x")
        check("checklist incomplete and completed literals",format("x",list("checklist item, incomplete")).description=="* [ ] x" && format("x",list("checklist item, completed")).description=="* [x] x")
        var incomplete=list("1.");incomplete.removeValue(forKey:.accessibilityListItemIndex)
        check("all three list attributes are required",format("x",incomplete).description=="x")
        incomplete=list("1.");incomplete[.accessibilityListItemPrefix]="1."
        check("list prefix requires attributed string",format("x",incomplete).description=="x")
        check("headings repeat on interior LF",format("a\nb",[key:"Title"]).description=="# a\n# b")
        check("interior structural LF has no source position",format("a\nb",[key:"Title"]).sourceOffsets==[nil,nil,0,nil,nil,nil,2])
        check("block trailing LF is retained but loses mapping",format("a\n",[key:"Title"]).description=="# a\n" && format("a\n",[key:"Title"]).sourceOffsets==[nil,nil,0,nil])
        check("final flush also moves plain trailing LF without source map",format("a\n").sourceOffsets==[0,nil])
        check("first LF only removed when followed by a Character",format("\n").description=="\n" && format("\nx",[key:"Title"]).description=="\n# x")
        check("CRLF stays one Character and is not replaced by block LF rule",format("a\r\nb",[key:"Title"]).description=="# a\r\nb")
        check("inline transition closes before moved newline",joined([("a\n",bold),("b",under)]).description=="**a**\n<u>b</u>")
        check("same block style is reintroduced after moved newline",joined([("a\n",[key:"Title"]),("b",[key:"Title",.init("unrelated"):1])]).description=="# a\n# b")
        let source=EventStreamMappedText(" e\u{301}😀 \n",range:NSRange(location:20,length:7)).trimmed()
        check("mapped trimming retains UTF16 positions for combining characters",source.text=="e\u{301}😀" && source.offsets==[21,22,23,24])
        var s=shortener(),captures:[String]=[]
        let url=URL(string:"https://www.example.com/a?q=1#z")!
        let describe:EventStreamAttributedMarkdown.DescribeElement={raw in
            captures.append(raw as! String)
            switch raw as! String {
            case "link":return .init(role:"AXLink",url:url,description:nil,roleDescription:"link")
            case "nil-url":return .init(role:"AXLink",url:nil,description:nil,roleDescription:nil)
            case "image":return .init(role:"AXImage",url:url,description:"alt",roleDescription:"image")
            case "button":return .init(role:"AXButton",url:nil,description:"fallback",roleDescription:"button")
            case "empty":return .init(role:"AXUnknown",url:nil,description:nil,roleDescription:nil)
            default:preconditionFailure()
            }
        }
        func withElement(_ text:String,_ attrs:[NSAttributedString.Key:Any])->EventStreamTransformedString {
            EventStreamAttributedMarkdown.format(NSAttributedString(string:text,attributes:attrs),shortener:&s,describe:describe)
        }
        let linked=withElement(" [é] \n",[.accessibilityLink:"link"])
        check("attributed link trims but does not escape brackets",linked.description=="[[é]](example.com/a?q=1#z)")
        check("link label maps selected source units and syntax maps nil",linked.sourceOffsets?.prefix(5).elementsEqual([nil,1,2,3,nil])==true && linked.sourceOffsets?.dropFirst(5).allSatisfy {$0==nil}==true)
        check("formatted attributed links are plain spans",linked.spans == [.string(linked.description)] && s.urls==[url])
        check("missing link URL preserves whitespace and run",withElement(" x ",[.accessibilityLink:"nil-url"]).description==" x ")
        check("image link rejection leaves source label and records URL",withElement("x",[.accessibilityLink:"image"]).description=="x" && s.urls.contains(url))
        check("placeholder attachment uses captured description",withElement("\u{fffc}",[.accessibilityAttachment:"button"]).description=="[button: fallback]")
        check("normal attachment candidate replaces fallback description without trimming",withElement(" x ",[.accessibilityAttachment:"button"]).description=="[button:  x ]")
        check("normal attachment placeholder drops source map",withElement("x",[.accessibilityAttachment:"button"]).sourceOffsets?.allSatisfy {$0==nil}==true)
        check("missing attachment metadata uses literal attachment",withElement("\u{fffc}",[.accessibilityAttachment:"empty"]).description=="[attachment]")
        check("image attachment rejected by URL shortener uses text placeholder",withElement("\u{fffc}",[.accessibilityAttachment:"image"]).description=="[image: alt]")
        let tail=withElement("a\nb",[.accessibilityAttachment:"button"])
        check("attachment newline preserves entire run as tail",tail.description=="[button: fallback] a\nb")
        check("attachment newline tail retains source positions",tail.sourceOffsets?.suffix(3).elementsEqual([0,1,2])==true)
        for scalar in ["\u{b}","\u{c}","\r","\u{85}","\u{2028}","\u{2029}"] {
            check("attachment recognizes newline scalar \(scalar.unicodeScalars.first!.value)",withElement("a"+scalar+"b",[.accessibilityAttachment:"empty"]).description=="[attachment] a"+scalar+"b")
        }
        captures=[]
        check("link rewrites before attachment",withElement("a",[.accessibilityLink:"link",.accessibilityAttachment:"button"]).description=="[button: [a](example.com/a?q=1#z)]" && captures==["link","button"])

        let ax=AXUIElementCreateApplication(getpid()),identity=EventStreamSnapshotAXIdentity(element:ax)
        var reads=0
        let native=EventStreamNativeAttributedMarkdown(capture:{element in
            reads += 1;precondition(CFEqual(element,ax))
            return EventStreamAXNode(element,supportedAttributes:["AXURL"],attributes:["AXRole":"AXLink" as NSString,"AXURL":url as NSURL,"AXDescription":"captured" as NSString],attributeReader:{_ in preconditionFailure("formatter must not read lazily")})
        })
        var ctx=EventStreamMacTransformationContext(type:.fullUIContext,urlShortener:shortener())
        let nativeInput=NSAttributedString(string:"x",attributes:[.accessibilityLink:ax])
        check("native AX resolver captures once and uses cached metadata",native.format(nativeInput,context:&ctx).description=="[x](example.com/a?q=1#z)" && reads==1 && ctx.urlShortener.urls.contains(url))
        let transaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:[identity:["AXRole":"AXLink" as NSString,"AXURL":url as NSURL]],requestedAttributes:["AXRole","AXURL"]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(transaction) {
            let actual=EventStreamNativeAttributedMarkdown()
            check("default native resolver inherits TaskLocal authoritative capture",actual.format(nativeInput,context:&ctx).description=="[x](example.com/a?q=1#z)")
        }
        let emptyTransaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:[identity:[:]],requestedAttributes:["AXRole","AXURL"]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(emptyTransaction) {
            let actual=EventStreamNativeAttributedMarkdown()
            check("authoritative empty capture has no fresh URL fallback",actual.format(nativeInput,context:&ctx).description=="x")
        }
        var io=EventStreamNativeAttributedTextIO.native
        io.attribute={_,_ in nil};io.parameterizedNames={_ in []};io.parameterized={_,_,_ in nativeInput}
        var node=EventStreamTransformedNode(element:EventStreamAXNode(ax,supportedAttributes:[]));node.role="AXTextArea";node.value="x"
        let item=EventStreamCollectedItem(node:node,path:[3],children:[],childrenSubset:nil)
        let result=try! EventStreamMacTreeTransform.transformAttributed(item,pass:.retrieveAttributedTextFromTextAreas,context:&ctx,backend:.init(),attributed:.init(io:io),formatter:native) {_,_ in preconditionFailure("must not render")}
        if case .transformed(let output)=result {
            check("native acquisition connects to the Markdown writer",output.node.value=="[x](example.com/a?q=1#z)" && output.node.attributedString === nativeInput && output.node.transformedString?.sourceOffsets?.contains(0)==true && output.path==[3])
        } else {check("native acquisition connects to the Markdown writer",false)}
        let process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--multi-scalar-attachment"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try! process.run();process.waitUntilExit()
        check("native multi-scalar attachment precondition is preserved",process.terminationStatus != 0 && process.terminationReason == .uncaughtSignal)
        print("Event-stream attributed Markdown: \(checks) checks passed")
    }
}
