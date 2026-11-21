import Foundation

@MainActor
private final class Node {
    var values: [String: String] = [:]
    var count: Int?
    var range: NSRange?
    var parameterized: String?
    var descendants: [Node] = []
    var stringReads: [String] = []
    var rangeReads: [NSRange] = []
    var childLimits: [Int] = []
    var countReads = 0
    init(_ values: [String: String] = [:]) { self.values = values }
}

@main
struct EventStreamAXTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    @MainActor static func main() {
        let reader = EventStreamAXContent<Node>(string: { node, attribute in node.stringReads.append(attribute); return node.values[attribute] },
            numberOfCharacters: { $0.countReads += 1; return $0.count }, visibleRange: { $0.range },
            stringForRange: { node, range in node.rangeReads.append(range); return node.parameterized },
            children: { node, limit in node.childLimits.append(limit); return node.descendants })
        let title = Node(["AXTitle":" \n First title \t", "AXDescription":"Second", "AXValue":"Third", "AXValueDescription":"Fourth", "AXPlaceholderValue":"Fifth"])
        check("title precedence and whitespace trimming pick the first title", reader.directTitle(title) == "First title")
        check("title reads all five cached candidates in order", title.stringReads == ["AXTitle","AXDescription","AXValue","AXValueDescription","AXPlaceholderValue"])
        title.values["AXTitle"] = "  "
        check("blank title falls through to description", reader.directTitle(title) == "Second")
        title.values["AXDescription"] = ""
        check("value is third title candidate", reader.directTitle(title) == "Third")
        title.values["AXValue"] = nil
        check("value description is fourth title candidate", reader.directTitle(title) == "Fourth")
        title.values["AXValueDescription"] = nil
        check("placeholder is fifth title candidate", reader.directTitle(title) == "Fifth")
        let root = Node(), a = Node(), b = Node(["AXTitle":"B"]), deep = Node(["AXTitle":"A deep"]), duplicate = Node(["AXDescription":"B"])
        a.descendants = [deep]; root.descendants = [a,b,duplicate]
        check("descendant labels are breadth-first and unique", reader.title(root) == "B A deep")
        check("descendant requests use eight children per parent", root.childLimits == [8] && a.childLimits == [8])
        let many = Node(); many.descendants = (0..<10).map { Node(["AXTitle":"label\($0)"]) }
        check("descendant label summary stops at six", reader.title(many) == "label0 label1 label2 label3 label4 label5")
        let limited = Node(); limited.descendants = (0..<8).map { _ in Node() } + [Node(["AXTitle":"ninth child"])]
        check("ninth child is excluded even if earlier children have no labels", reader.title(limited) == nil)
        let chain = Node(), first = Node(), second = Node(), third = Node(["AXTitle":"depth3"]), fourth = Node(["AXTitle":"depth4"])
        chain.descendants = [first];first.descendants = [second];second.descendants = [third];third.descendants = [fourth]
        check("descendant labels include depth three and exclude depth four", reader.title(chain) == "depth3")
        let cycle = Node(); cycle.descendants = [cycle]
        check("cycles terminate through depth limit", reader.title(cycle) == nil && cycle.childLimits.count == 3)
        let unicode = Node();unicode.descendants = [Node(["AXTitle":"é"]),Node(["AXTitle":"e\u{301}"]),Node(["AXTitle":"É"])]
        check("duplicate labels use Swift canonical string equality", reader.title(unicode) == "é É")
        let empty = reader.describe(Node())
        check("missing AX role becomes AXUnknown and missing fields remain nil", empty == .init(role:"AXUnknown"))
        let details = Node(["AXRole":"AXTextField","AXSubrole":"", "AXTitle":"Label", "AXDescription":"   ","AXValue":"Value","AXPlaceholderValue":"", "AXIdentifier":""])
        let description = reader.describe(details)
        check("empty subrole is retained while empty optional metadata is omitted", description.subrole == "" && description.description == "   " && description.placeholder == nil && description.identifier == nil)
        let nontext = Node(["AXRole":"AXButton","AXValue":String(repeating:"b",count:2000)])
        check("non-text values are not subject to text truncation", reader.value(nontext)?.count == 2000 && nontext.countReads == 0 && nontext.rangeReads.isEmpty)
        let absent = Node(["AXRole":"AXTextField","AXValue":""]);absent.count=5000
        check("empty value remains nil despite reported character count", reader.value(absent) == nil && absent.countReads == 0)
        let exact = Node(["AXRole":"AXTextField","AXValue":String(repeating:"x",count:1000)])
        check("one thousand UTF-16 units are unchanged", reader.value(exact) == exact.values["AXValue"] && exact.rangeReads.isEmpty)
        let long = Node(["AXRole":"AXTextArea","AXValue":String(repeating:"x",count:1001)])
        check("long value falls back to first thousand units with the truncation marker", reader.value(long) == "[truncated to visible range] " + String(repeating:"x",count:1000) && long.rangeReads == [NSRange(location:0,length:1000)])
        let visible = Node(["AXRole":"AXStaticText","AXValue":String(repeating:"0123456789",count:200)])
        visible.count=5000;visible.range=NSRange(location:123,length:80);visible.parameterized="native visible result"
        check("parameterized visible range is preferred", reader.value(visible) == "[truncated to visible range] native visible result" && visible.rangeReads == [NSRange(location:123,length:80)])
        visible.parameterized=""
        let expected = (visible.values["AXValue"]! as NSString).substring(with:NSRange(location:123,length:80))
        check("empty parameterized result falls back to cached NSString range", reader.value(visible) == "[truncated to visible range] " + expected)
        visible.range=NSRange(location:1800,length:2800)
        _=reader.value(visible)
        check("visible length is capped at thousand even if AX reports more content", visible.rangeReads.last == NSRange(location:1800,length:1000))
        visible.count=2100;visible.range=NSRange(location:2050,length:800);visible.parameterized="late native range"
        check("range clamps to total character count", reader.value(visible) == "[truncated to visible range] late native range" && visible.rangeReads.last == NSRange(location:2050,length:50))
        visible.parameterized=nil
        check("range beyond cached value with no native result yields nil", reader.value(visible) == nil)
        visible.range=NSRange(location:2100,length:50)
        _=reader.value(visible)
        check("out-of-bounds visible range falls back to start", visible.rangeReads.last == NSRange(location:0,length:1000))
        visible.range=NSRange(location:-1,length:Int.max)
        _=reader.value(visible)
        let negativeSafe=visible.rangeReads.last == NSRange(location:0,length:1000)
        visible.count=Int.max;visible.range=NSRange(location:1,length:Int.max)
        _=reader.value(visible)
        check("malformed and extreme native ranges stay bounded without overflow",negativeSafe && visible.rangeReads.last == NSRange(location:1,length:1000))
        visible.range=NSRange(location:100,length:0)
        _=reader.value(visible)
        check("empty visible range falls back to start", visible.rangeReads.last == NSRange(location:0,length:1000))
        let emoji = Node(["AXRole":"AXTextArea","AXValue":String(repeating:"🧪",count:600)])
        emoji.range=NSRange(location:1000,length:2)
        check("truncation uses UTF-16 ranges rather than Swift character offsets", reader.value(emoji) == "[truncated to visible range] 🧪")
        let shortCache = Node(["AXRole":"AXTextField","AXValue":"cached"]);shortCache.count=2000
        check("reported count can require truncation even for short cached value", reader.value(shortCache) == "[truncated to visible range] cached")
        let rawTitle = Node(["AXRole":"AXTextArea","AXValue":String(repeating:"t",count:1001)])
        check("title candidate uses the cached raw value independently of bounded value", reader.title(rawTitle)?.count == 1001 && reader.value(rawTitle)?.hasPrefix("[truncated to visible range]") == true)
        print("EVENT STREAM AX CONTENT: \(checks) checks passed")
    }
}
