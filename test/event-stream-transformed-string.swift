import Foundation

@main enum TransformedStringTests {
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func main() {
        setbuf(stdout,nil)
        typealias Text=EventStreamTransformedString
        var text=Text()
        check("empty interpolation storage has no spans or map",text.spans.isEmpty && text.description.isEmpty && text.sourceOffsets==nil)
        let literal:Text=""
        check("empty literal retains one empty string span",literal.spans == [.string("")] && literal.sourceOffsets==nil)
        text.append("a");text.append("😀");text.append("")
        check("adjacent strings coalesce including empty appends",text.spans == [.string("a😀")] && text.description=="a😀")
        check("ordinary strings do not allocate source maps",text.sourceOffsets==nil)
        let url=URL(string:"https://example.com/source?q=1")!
        text.append(.url("short",url,isImage:false));text.append(.url("image",url,isImage:true));text.append("after")
        check("URL spans retain source URL and image identity",text.spans == [.string("a😀"),.url("short",url,isImage:false),.url("image",url,isImage:true),.string("after")])
        check("description joins displayed strings without separators",text.description=="a😀shortimageafter")
        text.appendMappedString("é😀",sourceOffsets:[7,8,9])
        check("mapped string coalesces with last string",text.spans.last == .string("afteré😀"))
        check("initial mapping nil-pads previous displayed UTF-16 units",text.sourceOffsets==Array<Int?>(repeating:nil,count:"a😀shortimageafter".utf16.count)+[7,8,9])
        text.append("e\u{301}")
        check("ordinary appended text nil-pads combining UTF-16 units",text.sourceOffsets?.suffix(2).allSatisfy {$0==nil}==true && text.sourceOffsets?.count==text.description.utf16.count)
        text.append(.url("😀",url,isImage:true))
        check("URL display pads maps by UTF-16 length rather than grapheme count",text.sourceOffsets?.suffix(2).allSatisfy {$0==nil}==true && text.sourceOffsets?.count==text.description.utf16.count)
        var mapped=Text();mapped.appendMappedString("ab",sourceOffsets:[20,nil])
        var destination:Text="😀";destination.append(mapped)
        check("appending mapped text nil-pads an unmapped prefix",destination.sourceOffsets==[nil,nil,20,nil] && destination.description=="😀ab")
        destination.append(Text("é"))
        check("appending unmapped rich text preserves map and nil-pads suffix",destination.sourceOffsets==[nil,nil,20,nil,nil])
        destination.append(mapped)
        check("appending mapped text does not rebase absolute source offsets",destination.sourceOffsets==[nil,nil,20,nil,nil,20,nil])
        var ordinary=Text("a");ordinary.append(Text("b"))
        check("two unmapped rich strings keep nil sourceOffsets",ordinary.sourceOffsets==nil && ordinary.spans == [.string("ab")])
        ordinary.append(Text())
        check("empty rich append does not introduce a string span",ordinary.spans == [.string("ab")] && ordinary.sourceOffsets==nil)
        var emptyMap=Text();emptyMap.appendMappedString("",sourceOffsets:[])
        check("empty mapping is distinct from absent mapping",emptyMap.sourceOffsets != nil && emptyMap.sourceOffsets!.isEmpty && emptyMap.spans == [.string("")])
        emptyMap.append(.url("",url,isImage:true))
        check("empty displayed URL retains metadata and empty map",emptyMap.spans == [.string(""),.url("",url,isImage:true)] && emptyMap.sourceOffsets==[])
        emptyMap.append("")
        check("empty string after URL remains a distinct span",emptyMap.spans.last == .string("") && emptyMap.spans.count==3)
        var prefix:Text="before";prefix.append(emptyMap)
        check("an empty mapped source still initializes prefix nil mapping",prefix.sourceOffsets==Array<Int?>(repeating:nil,count:6) && prefix.description=="before")
        var copied=destination;copied.appendMappedString("x",sourceOffsets:[-1])
        check("source offsets retain supplied negative values",copied.sourceOffsets?.last == .some(-1))
        check("copied rich strings retain value semantics",destination.description=="😀abéab" && copied.description=="😀abéabx" && copied.sourceOffsets?.count==(destination.sourceOffsets?.count ?? 0)+1)
        mapped.append(mapped)
        check("self append preserves text and duplicates absolute maps",mapped.description=="abab" && mapped.sourceOffsets==[20,nil,20,nil])
        var separated=Text();separated.append(.url("u",url,isImage:false));separated.appendMappedString("x",sourceOffsets:[5]);separated.appendMappedString("y",sourceOffsets:[6])
        check("mapped appends respect URL span boundaries while coalescing strings",separated.spans == [.url("u",url,isImage:false),.string("xy")] && separated.sourceOffsets==[nil,5,6])
        var node=EventStreamTransformedNode(element:0);node.transformedString=separated
        check("transformed node retains rich URL spans and source maps",node.transformedString?.spans==separated.spans && node.transformedString?.sourceOffsets==[nil,5,6])
        var retrim=Text("before");retrim.append(.url("old",url,isImage:false));retrim.append(.url("image",url,isImage:true));retrim.append("after")
        var images:[Bool]=[]
        check("retrim visits URLs in span order and preserves flags",retrim.trimURLs {_,image in images.append(image);return image ? nil:"new"} && images==[false,true] && retrim.spans == [.string("before"),.url("new",url,isImage:false),.url("",url,isImage:true),.string("after")])
        images=[]
        check("unchanged URL display still invokes callback and returns false",!retrim.trimURLs {_,image in images.append(image);return image ? nil:"new"} && images==[false,true])
        var unmapped=Text("text");var calls=0
        check("string-only retrim invokes no callback",!unmapped.trimURLs {_,_ in calls += 1;return nil} && calls==0)
        var shortened=Text();shortened.appendMappedString("head",sourceOffsets:[1,2,3,4]);shortened.append(.url("abcdef",url,isImage:false));shortened.appendMappedString("end",sourceOffsets:[20,21,22])
        let oldMap=shortened.sourceOffsets
        check("retrim leaves existing source map unchanged after shortening",shortened.trimURLs {_,_ in "q"} && shortened.description=="headqend" && shortened.sourceOffsets==oldMap && shortened.sourceOffsets?.count==13)
        var suffix=Text();suffix.appendMappedString("z",sourceOffsets:[100]);shortened.append(suffix)
        check("rich append truncates old map prefix to current displayed length",shortened.sourceOffsets==[1,2,3,4,nil,nil,nil,nil,100] && shortened.description=="headqendz")
        var grown=Text();grown.appendMappedString("h",sourceOffsets:[1]);grown.append(.url("a",url,isImage:false))
        _ = grown.trimURLs {_,_ in "abcde"}
        grown.append(suffix)
        check("rich append preserves native short-map behavior after URL growth",grown.description=="habcdez" && grown.sourceOffsets==[1,nil,nil,100])
        var canonical=Text();canonical.append(.url("e\u{301}",url,isImage:false))
        check("canonical-equal retrim retains original UTF-16 spelling",!canonical.trimURLs {_,_ in "é"} && canonical.description.utf16.count==2)
        var removed=Text()
        removed.removeLast()
        check("removeLast with no spans is a no-op",removed.spans.isEmpty && removed.last==nil)
        removed.appendMappedString("ae\u{301}",sourceOffsets:[8,9,10]);removed.removeLast()
        check("removeLast removes an entire combining Character and UTF16 map",removed.description=="a" && removed.sourceOffsets==[8] && removed.last=="a")
        removed.removeLast()
        check("removeLast retains an empty string span",removed.spans == [.string("")] && removed.sourceOffsets==[] && removed.last==nil)
        removed.append(.url("😀",url,isImage:true));removed.removeLast()
        check("removeLast retains emptied URL identity and drops surrogate pair map",removed.spans.last == .url("",url,isImage:true) && removed.sourceOffsets==[])
        var lastSpan=Text("before");lastSpan.append(.url("",url,isImage:false))
        check("last does not search earlier spans across an empty final span",lastSpan.last==nil && lastSpan.description.last=="e")
        lastSpan.append(.url("\u{301}",url,isImage:false))
        check("last Character is read within the final span boundary",lastSpan.last==Character("\u{301}") && lastSpan.description.last != lastSpan.last)
        let sourceRangeCases: [(String, [Int?]?, NSRange, NSRange?)] = [
            ("missing map", nil, NSRange(location: 0, length: 2), nil),
            ("Markdown markers are excluded", [nil, nil, 10, 11, nil], NSRange(location: 0, length: 5), NSRange(location: 10, length: 2)),
            ("range covers source gaps", [0, 7], NSRange(location: 0, length: 2), NSRange(location: 0, length: 8)),
            ("duplicate offsets do not widen source selection", [6, 6], NSRange(location: 0, length: 2), NSRange(location: 6, length: 1)),
            ("syntax-only substring has no source range", [nil, nil, 8], NSRange(location: 0, length: 2), nil),
            ("one mapped UTF16 unit remains selectable", [5, 6], NSRange(location: 1, length: 1), NSRange(location: 6, length: 1)),
            ("empty range is not a source selection", [0, 1], NSRange(location: 0, length: 0), nil),
            ("out-of-bounds range is rejected", [0, 1], NSRange(location: 1, length: 2), nil),
            ("not-found range is rejected", [0, 1], NSRange(location: NSNotFound, length: 0), nil),
            ("source arithmetic overflow returns no range", [Int.min, Int.max], NSRange(location: 0, length: 2), nil)
        ]
        for (name, offsets, input, expected) in sourceRangeCases {
            var mapped = Text()
            if let offsets { mapped.appendMappedString(String(repeating: "x", count: offsets.count), sourceOffsets: offsets) }
            check(name, mapped.sourceRange(forMarkdownRange: input) == expected)
        }
        var staleMap = Text()
        staleMap.appendMappedString("prefix", sourceOffsets: [10, 11, 12, 13, 14, 15])
        staleMap.append(.url("abcdef", url, isImage: false))
        staleMap.appendMappedString("end", sourceOffsets: [20, 21, 22])
        _ = staleMap.trimURLs { _, _ in "q" }
        check("source lookup uses the retained map bounds after URL trimming",
              staleMap.sourceRange(forMarkdownRange: NSRange(location: 12, length: 3)) == NSRange(location: 20, length: 3))
        print("Event-stream transformed strings: \(checks) checks passed")
    }
}
