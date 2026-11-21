import Foundation

enum TextSelection {
    /// AX uses UTF-16 offsets. Never use String.count/distance for CFRange.
    static func range(in value: String, text: String, prefix: String? = nil,
                      suffix: String? = nil, selection: String = "text") throws -> NSRange {
        guard ["text", "cursor_before", "cursor_after"].contains(selection) else {
            throw ServiceError(.unhandledEvent, "Unknown text selection mode '\(selection)'")
        }
        guard !text.isEmpty else {
            throw ServiceError(.unhandledEvent, "Text to select must not be empty")
        }
        let source = value as NSString
        let prefixLength = (prefix as NSString?)?.length ?? 0
        let suffixLength = (suffix as NSString?)?.length ?? 0
        var search = NSRange(location: 0, length: source.length)
        var match: NSRange?
        while search.location <= source.length {
            let found = source.range(of: text, options: [], range: search)
            if found.location == NSNotFound { break }
            // Match context over the supplied UTF-16 length,
            // then compares those exact substrings using Swift String equality.
            if found.location >= prefixLength, source.length - NSMaxRange(found) >= suffixLength,
               prefix == nil || source.substring(with: NSRange(location: found.location - prefixLength, length: prefixLength)) == prefix!,
               suffix == nil || source.substring(with: NSRange(location: NSMaxRange(found), length: suffixLength)) == suffix! {
                guard match == nil else {
                    throw ServiceError(.accessibilityError, "Text matches more than once; provide a distinguishing prefix or suffix")
                }
                match = found
            }
            // Advance by a complete Unicode scalar, preserving overlapping matches
            // without starting an NSString search inside a surrogate pair.
            var next = found.location + 1
            if next < source.length {
                let unit = source.character(at: next)
                if (0xDC00...0xDFFF).contains(unit) { next += 1 }
            }
            search = NSRange(location: next, length: source.length - next)
        }
        guard let match else { throw ServiceError(.accessibilityError, "Text and its supplied context were not found") }
        switch selection {
        case "cursor_before": return NSRange(location: match.location, length: 0)
        case "cursor_after": return NSRange(location: NSMaxRange(match), length: 0)
        default: return match
        }
    }
}
