import AppKit
import Foundation
import ObjectiveC

private struct RichCorpus: Decodable {
    struct Row: Decodable { let name:String; let text:String; let html:String; let plain:String; let rtf_base64:String }
    let known_document_UUID_cases:[String]
    let known_semantically_equal_nonidentical_RTF_cases:[String]
    let cases:[Row]
}

@main struct MarkdownRichRegression {
    @MainActor static func main() async throws {
        let corpus = try JSONDecoder().decode(RichCorpus.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        precondition(corpus.cases.count == 104 && Set(corpus.cases.map(\.name)).count == 104)
        let UUIDCases = Set(corpus.known_document_UUID_cases)
        let imageCases = Set(corpus.known_semantically_equal_nonidentical_RTF_cases)
        precondition(UUIDCases == ["footnote","smart-link-title","link-percent-quote"])
        precondition(imageCases == ["image","image-emphasis","image-quoted-title"])
        let method = class_getClassMethod(NSPasteboard.self,NSSelectorFromString("generalPasteboard"))!
        let board = NSPasteboard.withUniqueName()
        let getter: @convention(block) (AnyObject) -> NSPasteboard = { _ in board }
        let replacement = imp_implementationWithBlock(getter)
        let previous = method_setImplementation(method,replacement)
        defer { method_setImplementation(method,previous); imp_removeBlock(replacement); board.releaseGlobally() }
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let UUID = try NSRegularExpression(pattern:"applewebdata://[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/")
        func normalize(_ data:Data) -> Data {
            let value = String(data:data,encoding:.utf8)!
            return Data(UUID.stringByReplacingMatches(in:value,range:NSRange(value.startIndex...,in:value),withTemplate:"applewebdata://00000000-0000-0000-0000-000000000000/").utf8)
        }
        func readRTF(_ data:Data) throws -> NSAttributedString {
            try NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        }
        var rows = [[String:Any]](), negativeChecks = [[String:Any]]()
        for sample in corpus.cases {
            let result = try await ControllerPasteRendering.native.representations(text:sample.text,format:.markdown)
            precondition(result.map(\.type) == ["public.html","public.rtf","public.utf8-plain-text"])
            let expectedRTF = Data(base64Encoded:sample.rtf_base64)!
            let exact = result[1].data == expectedRTF
            let onlyUUID = UUIDCases.contains(sample.name) && normalize(result[1].data) == normalize(expectedRTF)
            var imageEquivalent = false
            if imageCases.contains(sample.name) {
                let expected = try readRTF(expectedRTF)
                let control = try readRTF(expectedRTF)
                let actual = try readRTF(result[1].data)
                imageEquivalent = expected.isEqual(to:control) && expected.isEqual(to:actual)
                // Exercise the exception's oracle with actual material changes.
                for (kind,key,value) in [("color",NSAttributedString.Key.foregroundColor,NSColor.red as Any),
                                         ("font",.font,NSFont.systemFont(ofSize:30) as Any)] {
                    let changed = NSMutableAttributedString(attributedString:actual)
                    changed.addAttribute(key,value:value,range:NSRange(location:0,length:changed.length))
                    negativeChecks.append(["name":sample.name+"-reject-"+kind,"passed":!expected.isEqual(to:changed)])
                }
                let changedText = NSMutableAttributedString(attributedString:actual)
                changedText.append(NSAttributedString(string:"changed"))
                negativeChecks.append(["name":sample.name+"-reject-content","passed":!expected.isEqual(to:changedText)])
            }
            let htmlEqual = result[0].data == Data(sample.html.utf8)
            let plainEqual = result[2].data == Data(sample.plain.utf8)
            rows.append(["name":sample.name,"passed":htmlEqual && plainEqual && (exact || onlyUUID || imageEquivalent),
                         "HTML_bytes_equal":htmlEqual,"plain_UTF8_bytes_equal":plainEqual,"RTF_bytes_equal":exact,
                         "RTF_equal_except_document_UUID":onlyUUID,"known_image_RTF_attributes_equal":imageEquivalent])
        }
        let foregroundUnchanged = foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true } && negativeChecks.allSatisfy { $0["passed"] as? Bool == true } && foregroundUnchanged
        let report:[String:Any] = ["passed":passed,"cases":rows,"negative_checks":negativeChecks,
                                  "all_RTF_bytes_identical":rows.allSatisfy { $0["RTF_bytes_equal"] as? Bool == true },
                                  "foregroundUnchanged":foregroundUnchanged,"activationProhibited":NSApplication.shared.activationPolicy() == .prohibited,
                                  "general_clipboard_or_physical_input_used":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        print("Markdown rich corpus: \(rows.filter { $0["passed"] as? Bool == true }.count)/104; RTF raw bytes \(rows.filter { $0["RTF_bytes_equal"] as? Bool == true }.count)/104; negative controls \(negativeChecks.filter { $0["passed"] as? Bool == true }.count)/9")
        if !passed { exit(1) }
    }
}
