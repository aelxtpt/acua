import AppKit
import Foundation

private struct RichMarkdownCorpus: Decodable {
    struct Sample: Decodable { let name: String; let text: String; let html: String }
    let cases: [Sample]
}
@MainActor enum NativePasteRichChecks {
    static func run(output: URL, markdownCorpus: URL, resourceURL: URL, scope: OwnedRichConversionScope) async throws -> Int32 {
        var cases: [[String:Any]] = []
        func check(_ name: String,_ value: Bool) { cases.append(["name":name,"passed":value]); if !value { print("FAIL: "+name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let corpus = try JSONDecoder().decode(RichMarkdownCorpus.self,from:Data(contentsOf:markdownCorpus))
        precondition(corpus.cases.count == 104)
        for sample in corpus.cases {
            let actual = try await ControllerPasteRendering.native.markdownToHTML(sample.text)
            check("golden Markdown HTML: "+sample.name,actual?.utf8.elementsEqual(sample.html.utf8) == true)
        }
        let text = try await ControllerPasteRendering.native.representations(text:"literal **a**\u{0}😀",format:.text)
        check("default text preserves UTF8 without any HTML conversion",text == [.init(type:"public.utf8-plain-text",data:Data("literal **a**\u{0}😀".utf8))])
        let samples: [(String,String,String)] = [
            ("bold entities unicode","<p><b>bold</b> &amp; café 😀</p>","bold & café 😀\n"),
            ("line breaks","a<br>b","a\nb"),
            ("paragraphs","<p>one</p><p>two</p>","one\ntwo\n"),
            ("inline styles","<span style='font-weight:bold'>bold</span><i> italic</i>","bold italic"),
            ("empty HTML","",""),
            ("malformed HTML","<p><b>unfinished","unfinished\n")
        ]
        for (name,html,expected) in samples {
            let result = try await ControllerPasteRendering.native.representations(text:html,format:.html)
            check("native HTML representations preserve source and order: "+name,result.map(\.type) == ["public.html","public.rtf","public.utf8-plain-text"] && result[0].data == Data(html.utf8))
            check("native HTML plain text: "+name,result[2].data == Data(expected.utf8))
            let decoded = try NSAttributedString(data:result[1].data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
            check("native RTF round trip: "+name,decoded.string == expected)
        }
        let md = try await ControllerPasteRendering.native.representations(text:"**bold** and [link](https://example.invalid/)",format:.markdown)
        let mdRich = try NSAttributedString(data:md[1].data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        check("default Markdown conversion reaches actual HTML RTF and plain representations",String(data:md[0].data,encoding:.utf8) == "<p><strong>bold</strong> and <a href=\"https://example.invalid/\">link</a></p>\n" && String(data:md[2].data,encoding:.utf8) == "bold and link\n" && mdRich.string == "bold and link\n")
        let boldFont = mdRich.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        check("RTF preserves bold font traits",boldFont.map { NSFontManager.shared.traits(of:$0).contains(.boldFontMask) } == true)
        check("RTF preserves link attribute",(mdRich.attribute(.link,at:9,effectiveRange:nil) as? URL)?.absoluteString == "https://example.invalid/")
        let attributed = NSMutableAttributedString(string:"aXbYc")
        attributed.addAttribute(ControllerNativePasteRichConversion.viewAttachment,value:ControllerPasteViewAttachment.html("<b>long</b>"),range:NSRange(location:1,length:1))
        attributed.addAttribute(ControllerNativePasteRichConversion.viewAttachment,value:ControllerPasteViewAttachment.html("<i>other</i>"),range:NSRange(location:3,length:1))
        let attachmentRTF = ControllerNativePasteRichConversion.rtf(from:attributed)
        let flattened = try attachmentRTF.map { try NSAttributedString(data:$0,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil) }
        check("view attachments replace ranges in reverse before RTF export",flattened?.string == "alongbotherc")
        check("RTF export does not mutate the input attributed source",attributed.string == "aXbYc" && attributed.attribute(ControllerNativePasteRichConversion.viewAttachment,at:1,effectiveRange:nil) != nil)
        let unsupported = NSMutableAttributedString(string:"keep")
        unsupported.addAttribute(ControllerNativePasteRichConversion.viewAttachment,value:ControllerPasteViewAttachment.unsupported,range:NSRange(location:0,length:4))
        let unsupportedData = ControllerNativePasteRichConversion.rtf(from:unsupported)!
        let retained = try NSAttributedString(data:unsupportedData,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        check("unsupported view attachment retains characters while its attribute is removed",retained.string == "keep" && retained.attribute(ControllerNativePasteRichConversion.viewAttachment,at:0,effectiveRange:nil) == nil)
        let resourceHTML = "<html><head><link rel='stylesheet' href='\(resourceURL.absoluteString)/style.css'></head><body><p>owned resource check</p><img src='\(resourceURL.absoluteString)/image.png'></body></html>"
        let resourceResult = try await ControllerPasteRendering.native.representations(text:resourceHTML,format:.html)
        check("native resource delegate rejects real subsidiary requests",scope.blockedResources.contains(resourceURL.absoluteString+"/style.css") && scope.blockedResources.contains(resourceURL.absoluteString+"/image.png") && scope.blockedResources.allSatisfy { $0 == "about:blank" || $0.hasPrefix(resourceURL.absoluteString) })
        check("HTML with blocked resources still produces complete representations",resourceResult.count == 3 && String(data:resourceResult[2].data,encoding:.utf8)?.contains("owned resource check") == true)
        check("HTML importer stays nonactivating and private clipboard namespace is substituted",foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier && NSApplication.shared.activationPolicy() == .prohibited && scope.ownedName != NSPasteboard.Name.general.rawValue)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,"golden_markdown_cases_matched":cases.prefix(104).allSatisfy { $0["passed"] as? Bool == true },"native_HTML_RTF_and_plain_conversion_executed":true,"blocked_resources":scope.blockedResources,"owned_general_getter_calls":scope.generalGetterCalls,"real_general_clipboard_used":false,"actual_input_focus_or_capture_executed":false,"whole_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native rich conversion: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0:3
    }
}
