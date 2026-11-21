import AppKit
import Foundation

/// Returns nil for every subsidiary request. Dynamic Objective-C
/// dispatch avoids depending on the deprecated WebKit delegate protocol import.
final class ControllerPasteResourceLoadBlocker: NSObject {
    @objc(webView:resource:willSendRequest:redirectResponse:fromDataSource:)
    func request(_ webView: Any?, resource: Any?, willSendRequest request: NSURLRequest?,
                 redirectResponse: URLResponse?, fromDataSource: Any?) -> NSURLRequest? { nil }
}

/// Value carried by the viewAttachment attribute. Other representation
/// kinds do not produce the HTML substitution performed by `rtf(from:)`.
enum ControllerPasteViewAttachment: Sendable { case html(String), unsupported }

enum ControllerNativePasteRichConversion {
    static let viewAttachment = NSAttributedString.Key("viewAttachment")

    /// Performs this synchronous AppKit import on the conversion's
    /// generic executor, retaining the resource delegate until it returns.
    static func attributed(fromHTML html: String) throws -> NSAttributedString {
        let blocker = ControllerPasteResourceLoadBlocker()
        return try NSAttributedString(data:Data(html.utf8),options:[
            .documentType:NSAttributedString.DocumentType.html,
            .characterEncoding:String.Encoding.utf8.rawValue,
            .timeout:Double(2),
            .webResourceLoadDelegate:blocker
        ],documentAttributes:nil)
    }

    /// Copies before replacing view attachments in reverse, removes the
    /// attribute over the resulting range and calls RTFFromRange with EMPTY
    /// document attributes. The input attributed value stays unchanged.
    static func rtf(from attributed: NSAttributedString) -> Data? {
        let copy = NSMutableAttributedString(attributedString:attributed)
        copy.enumerateAttribute(viewAttachment,in:NSRange(location:0,length:copy.length),options:.reverse) { value,range,_ in
            guard let source = value as? ControllerPasteViewAttachment, case .html(let html) = source,
                  let replacement = NSAttributedString(html:Data(html.utf8),documentAttributes:nil) else { return }
            copy.replaceCharacters(in:range,with:replacement)
        }
        copy.removeAttribute(viewAttachment,range:NSRange(location:0,length:copy.length))
        return copy.rtf(from:NSRange(location:0,length:copy.length),documentAttributes:[:])
    }

    nonisolated static func richBytes(fromHTML html: String) async throws -> ControllerPasteRichBytes? {
        let attributed = try attributed(fromHTML:html)
        guard let data = rtf(from:attributed) else { return nil }
        return .init(rtf:data,plainText:attributed.string)
    }
}

extension ControllerPasteRendering {
    static var native: Self {
        .init(markdownToHTML:{ try MarkdownHTML.render($0) },htmlToRichBytes:{ try await ControllerNativePasteRichConversion.richBytes(fromHTML:$0) })
    }
}
