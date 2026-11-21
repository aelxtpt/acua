import Foundation

struct ControllerPasteRichBytes: Sendable { let rtf: Data; let plainText: String }

/// Conversion results are required before constructing
/// a provider or taking ownership. Native rich converters are a required input.
struct ControllerPasteRendering: Sendable {
    let markdownToHTML: @Sendable (String) async throws -> String?
    let htmlToRichBytes: @Sendable (String) async throws -> ControllerPasteRichBytes?
    func representations(text: String, format: ControllerPasteFormat) async throws -> [ControllerPasteRepresentation] {
        if format == .text { return [.init(type:"public.utf8-plain-text",data:Data(text.utf8))] }
        let html: String
        if format == .markdown {
            guard let converted = try await markdownToHTML(text) else { throw ControllerPasteEngineFailure.failedToProvideData }
            html = converted
        } else { html = text }
        guard let rich = try await htmlToRichBytes(html) else { throw ControllerPasteEngineFailure.failedToProvideData }
        return [.init(type:"public.html",data:Data(html.utf8)), .init(type:"public.rtf",data:rich.rtf),
            .init(type:"public.utf8-plain-text",data:Data(rich.plainText.utf8))]
    }
}
