import Foundation

// TransformedUIString stores rich spans, not just a rendered String. URL spans
// retain their source URL and image flag even when their displayed text is empty.
struct EventStreamTransformedString:ExpressibleByStringLiteral,CustomStringConvertible,Equatable {
    enum Span:Equatable {
        case string(String)
        case url(String,URL,isImage:Bool)
        var text:String {
            switch self {case .string(let text),.url(let text,_,_):return text}
        }
    }
    private(set) var spans:[Span]=[]
    private(set) var sourceOffsets:[Int?]?
    var description:String {spans.map(\.text).joined()}
    // Consult only the final span, including an empty one.
    var last:Character? {spans.last?.text.last}
    init() {}
    init(stringLiteral value:String) {spans=[.string(value)]}
    init(_ value:String) {spans=[.string(value)]}

    // Retain the final span and its URL metadata when emptied.
    // A map made stale by trimURLs is not repaired here.
    mutating func removeLast() {
        guard let span=spans.last else {return}
        var text=span.text
        let removed=text.removeLast()
        switch span {
        case .string:spans[spans.count-1] = .string(text)
        case .url(_,let url,let image):spans[spans.count-1] = .url(text,url,isImage:image)
        }
        if sourceOffsets != nil {sourceOffsets!.removeLast(String(removed).utf16.count)}
    }

    private mutating func appendStorage(_ span:Span) {
        if case .string(let incoming)=span,let last=spans.last,case .string(let previous)=last {
            spans[spans.count-1] = .string(previous+incoming)
        } else {spans.append(span)}
    }
    // Coalesce adjacent string spans and extend any existing map
    // with nil for every UTF-16 unit in the newly displayed span.
    mutating func append(_ span:Span) {
        appendStorage(span)
        if sourceOffsets != nil {sourceOffsets!.append(contentsOf:Array(repeating:nil,count:span.text.utf16.count))}
    }
    mutating func append(_ text:String) {append(.string(text))}

    // Maps are absolute source offsets. They are not
    // rebased by destination length; unmapped prefixes/suffixes are nil-filled.
    mutating func append(_ other:Self) {
        let prefixLength=description.utf16.count
        let suffix=other.sourceOffsets
        for span in other.spans {append(span)}
        if sourceOffsets != nil || suffix != nil {
            sourceOffsets=(sourceOffsets.map {Array($0.prefix(prefixLength))} ?? Array(repeating:nil,count:prefixLength))
                + (suffix ?? Array(repeating:nil,count:other.description.utf16.count))
        }
    }
    // Assert the same UTF-16 count before changing storage.
    mutating func appendMappedString(_ text:String,sourceOffsets offsets:[Int?]) {
        precondition(text.utf16.count==offsets.count,"source offset count must equal UTF-16 length")
        let prefixLength=description.utf16.count
        appendStorage(.string(text))
        if sourceOffsets==nil {sourceOffsets=Array(repeating:nil,count:prefixLength)}
        sourceOffsets!.append(contentsOf:offsets)
    }
    // Change only URL display strings, in span order.
    // It intentionally leaves sourceOffsets untouched even if lengths change.
    @discardableResult mutating func trimURLs(_ trim:(URL,Bool)->String?) -> Bool {
        var changed=false
        for index in spans.indices {
            guard case .url(let old,let url,let image)=spans[index] else {continue}
            let next=trim(url,image) ?? ""
            if next != old {spans[index] = .url(next,url,isImage:image);changed=true}
        }
        return changed
    }
    // Retain only the first nonempty result's rich representation.
    // Later parts append separator+description as plain text, losing their maps
    // and URL spans. The empty test is structural (one empty span or no spans).
    static func joined(_ parts:[Self],separator:String) -> Self {
        var result:Self=""
        for part in parts {
            if result.spans.isEmpty || (result.spans.count==1 && result.spans[0].text.isEmpty) {result=part}
            else {result.append(separator+part.description)}
        }
        return result
    }

    // Ignore formatting-only units and cover the source interval
    // between the first and last mapped UTF-16 units in the requested span.
    func sourceRange(forMarkdownRange range: NSRange) -> NSRange? {
        guard let sourceOffsets, range.location >= 0, range.location != NSNotFound,
              range.length > 0, range.location <= sourceOffsets.count,
              range.length <= sourceOffsets.count - range.location else { return nil }
        let positions = sourceOffsets[range.location..<(range.location + range.length)].compactMap { $0 }
        guard let first = positions.first, let last = positions.last else { return nil }
        let (distance, distanceOverflow) = last.subtractingReportingOverflow(first)
        let (length, lengthOverflow) = distance.addingReportingOverflow(1)
        guard !distanceOverflow, !lengthOverflow else { return nil }
        return NSRange(location: first, length: length)
    }
}
