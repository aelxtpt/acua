import Foundation

extension EventStreamTransformedString {
    @discardableResult mutating func trimURLs(shortener:inout EventStreamURLShortener) -> Bool {
        trimURLs {url,image in shortener.trim(url:url,isImage:image)}
    }
    //0x1006438AC: missing/filtered display still retains the URL span.
    mutating func appendURL(_ url:URL,role:String?,shortener:inout EventStreamURLShortener) {
        let image=role=="AXImage"
        append(.url(shortener.trim(url:url,isImage:image) ?? "",url,isImage:image))
    }
    //0x1006450E0: choose first nonempty raw value BEFORE whitespace trimming;
    // escape only square brackets, then trim. Whitespace-only values win.
    mutating func appendMarkdownLink(url:URL,role:String,stringValue:String?,title:String?,description:String?,
                                    shortener:inout EventStreamURLShortener) {
        var link=EventStreamTransformedString()
        if let raw=[stringValue,title,description].compactMap({$0}).first(where:{!$0.isEmpty}) {
            let label=raw.replacing("[",with:"\\[").replacing("]",with:"\\]")
                .trimmingCharacters(in:.whitespacesAndNewlines)
            link.append("[");link.append(label);link.append("](")
            link.appendURL(url,role:role,shortener:&shortener);link.append(")")
        } else {
            link.append("<");link.appendURL(url,role:role,shortener:&shortener);link.append(">")
        }
        append(link)
    }
}
