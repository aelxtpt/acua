import Foundation

/// NSString searches advance one UTF-16 unit after each match,
/// including overlaps. Context lengths are UTF-16; context equality is Swift's.
enum ControllerVisibleTextMatches {
    static func unique(in value: String, text: String, prefix: String?, suffix: String?) -> NSRange? {
        guard !text.isEmpty else { return nil }
        let source = value as NSString
        guard source.length > 0 else { return nil }
        let before = (prefix as NSString?)?.length ?? 0
        let after = (suffix as NSString?)?.length ?? 0
        var matches: [NSRange] = [], start = 0
        while start < source.length {
            let found = source.range(of: text, options: [], range: .init(location: start, length: source.length-start))
            guard found.location != NSNotFound else { break }
            let end = found.location + found.length
            if found.location >= before, end + after <= source.length,
               prefix == nil || source.substring(with: .init(location: found.location-before, length: before)) == prefix,
               suffix == nil || source.substring(with: .init(location: end, length: after)) == suffix {
                matches.append(found)
            }
            start = found.location + 1
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ControllerSelectionSource: Sendable {
    var displayedRichText: String? = nil
    var sourceOffsets: [Int?]? = nil
    var attributedText: String? = nil
    var stringValue: String? = nil
    var truncationOffset = 0
}
enum ControllerSelectionSourceRange {
    /// Try the rich map first, then attributed text or stringValue.
    /// Source offset addition is overflow-checked.
    static func resolve(_ source: ControllerSelectionSource, text: String, prefix: String?, suffix: String?) -> NSRange? {
        var result: NSRange?
        if let display = source.displayedRichText, let offsets = source.sourceOffsets,
           let match = ControllerVisibleTextMatches.unique(in: display, text: text, prefix: prefix, suffix: suffix),
           match.location >= 0, match.location != NSNotFound, match.length >= 0 {
            let end = match.location + match.length
            if end <= offsets.count {
                let mapped = offsets[match.location..<end].compactMap { $0 }
                if let first = mapped.first, let last = mapped.last {
                    result = .init(location: first, length: last-first+1)
                }
            }
        }
        if result == nil, let value = source.attributedText ?? source.stringValue {
            result = ControllerVisibleTextMatches.unique(in: value, text: text, prefix: prefix, suffix: suffix)
        }
        guard let result else { return nil }
        return .init(location: result.location + source.truncationOffset, length: result.length)
    }
}
