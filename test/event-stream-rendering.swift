import Foundation

@main enum EventStreamRenderingTests {
    static var checks = 0
    static func check(_ label: String, _ result: @autoclosure () -> Bool) {
        guard result() else { fatalError("FAIL: \(label)") }
        checks += 1; print("PASS: \(label)")
    }
    static func main() throws {
        setbuf(stdout, nil)
        check("absent attributes render no text", EventStreamPresentation().attributesDescription.isEmpty)
        check("sole named field has no redundant label", EventStreamPresentation(description:"Open").attributesDescription == "Open")
        let fields = EventStreamPresentation(title:"Open",description:"Document",trimmedURL:"https://example.test/a",help:"Help",value:"Text",details:"Detail",placeholder:"Type",identifier:"editor")
        check("multiple fields use fixed labels and order", fields.attributesDescription == "Open, Description: Document, URL: https://example.test/a, Help: Help, Value: Text, Details: Detail, Placeholder: Type, ID: editor")
        check("role and state precede attributes", fields.accessibilityDescription(role:"text area",state:"(settable)") == "text area (settable) " + fields.attributesDescription)
        check("empty description components add no spaces", EventStreamPresentation().accessibilityDescription(role:"button",state:"") == "button")
        check("empty and duplicate strings are removed by value", EventStreamPresentation(title:"Same",description:"Same",help:"",value:"Same").attributesDescription == "Same")
        check("canonical Unicode equality deduplicates values", EventStreamPresentation(title:"é",description:"e\u{301}").attributesDescription == "é")
        check("whitespace and raw punctuation remain literal", EventStreamPresentation(title:" ",description:"\"x\"\\y").attributesDescription == " , Description: \"x\"\\y")
        let long = String(repeating:"x",count:101)
        check("long title moves after short named attribute", EventStreamPresentation(title:long,help:"Short").attributesDescription == "Help: Short, " + long)
        check("long attributes preserve relative order", EventStreamPresentation(title:long,description:long+"2",help:"Short").attributesDescription == "Help: Short, " + long + ", Description: " + long + "2")
        let hundred = String(repeating:"👨‍👩‍👧‍👦",count:100)
        check("100 graphemes remain short despite many UTF16 units", EventStreamPresentation(title:hundred,help:"Short").attributesDescription == hundred + ", Help: Short")
        let hundredOne = hundred + "e\u{301}"
        check("101 graphemes reach the long threshold", EventStreamPresentation(title:hundredOne,help:"Short").attributesDescription == "Help: Short, " + hundredOne)
        check("short multiline value moves after single-line field", EventStreamPresentation(title:"a\nb",help:"Short").attributesDescription == "Help: Short, a\nb")
        check("carriage return alone does not use LF long rule", EventStreamPresentation(title:"a\rb",help:"Short").attributesDescription == "a\rb, Help: Short")
        check("sole multiline value keeps original newlines", EventStreamPresentation(value:"a\nb").attributesDescription == "a\nb")
        check("framework and private identifiers are omitted", EventStreamPresentation(identifier:"NSButton42").attributesDescription.isEmpty && EventStreamPresentation(identifier:"_private").attributesDescription.isEmpty)
        check("identifier prefix matching is case sensitive", EventStreamPresentation(identifier:"nsButton42").attributesDescription == "nsButton42")
        let ignored = ["Add comment", "Remove unused rows", "Remove unused columns", "Remove unused rows and columns"]
        let actions = [EventStreamPresentation.Action(kind:0,description:"Press"),.init(kind:1,description:"Open"),.init(kind:2,description:"Show menu")] + ignored.map { .init(kind:3,description:$0) }
        check("primary kinds and four exact action names are filtered", EventStreamPresentation(actions:actions).attributesDescription.isEmpty)
        check("sole secondary action retains its field label", EventStreamPresentation(actions:[.init(kind:3,description:"Export")]).attributesDescription == "Secondary Actions: Export")
        check("secondary actions preserve order and duplicate descriptions", EventStreamPresentation(actions:[.init(kind:3,description:"Export"),.init(kind:255,description:"Export"),.init(kind:4,description:"add comment")]).attributesDescription == "Secondary Actions: Export, Export, add comment")
        check("action field participates in whole-value dedup", EventStreamPresentation(title:"Export",actions:[.init(kind:3,description:"Export")]).attributesDescription == "Export")
        check("row and column inclusive ranges bypass ordinary value dedup", EventStreamPresentation(title:"0-3",rows:0...3,columns:0...3,value:"0-3").attributesDescription == "0-3, Rows: 0-3, Columns: 0-3")
        check("negative or singleton inclusive ranges are omitted", EventStreamPresentation(rows:(-1)...3,columns:2...2).attributesDescription.isEmpty)
        check("single range follows ordinary single-field formatting", EventStreamPresentation(rows:0...Int.max).attributesDescription == "0-\(Int.max)")

        func role(_ name: String, _ description: String?) -> EventStreamPresentationRole { .init(nativeRole:name,roleDescription:description) }
        check("native role mapping preserves role descriptions", role("AXButton","Botão").kind == .button && role("AXButton","Botão").description(contextKind:0) == "Botão")
        check("row role is normalized when a description is present", role("AXRow","linha localizada").description(contextKind:0) == "row")
        check("missing row description remains unknown", role("AXRow",nil).description(contextKind:0) == "unknown")
        check("generic distinguishes empty description from missing description", role("AXGenericElement","").description(contextKind:0) == "element" && role("AXGenericElement",nil).description(contextKind:0) == "unknown")
        check("generic nonempty description remains literal", role("AXGenericElement","article").description(contextKind:0) == "article")
        check("group maps to container only when description exists", role("AXGroup","").description(contextKind:0) == "container" && role("AXGroup",nil).description(contextKind:0) == "unknown")
        check("menu labels have exact missing-description fallbacks", role("AXMenu",nil).description(contextKind:2) == "menu" && role("AXMenuBar",nil).description(contextKind:2) == "menu bar")
        check("omitted menu and radio roles remain unlabeled", ["AXMenuItem","AXMenuBarItem","AXRadioGroup"].allSatisfy { role($0,"localized").description(contextKind:0).isEmpty && role($0,nil).description(contextKind:0).isEmpty })
        check("context2 suppresses unknown rather than known descriptions", role("AXCustom",nil).description(contextKind:2).isEmpty && role("AXCustom","custom").description(contextKind:2) == "custom")
        check("selectable appears only in context0 and selected takes precedence", EventStreamPresentationState(isSelectable:true).description(role:role("AXButton","button"),contextKind:0) == "(selectable)" && EventStreamPresentationState(isSelectable:true).description(role:role("AXButton","button"),contextKind:1).isEmpty && EventStreamPresentationState(isSelectable:true,isSelected:true).description(role:role("AXButton","button"),contextKind:2) == "(selected)")
        check("disabled excludes groups and static text", EventStreamPresentationState(isEnabled:false).description(role:role("AXButton","button"),contextKind:0) == "(disabled)" && ["AXGroup","AXStaticText"].allSatisfy { EventStreamPresentationState(isEnabled:false).description(role:role($0,nil),contextKind:0).isEmpty })
        check("context2 suppresses disabled state", EventStreamPresentationState(isEnabled:false).description(role:role("AXButton","button"),contextKind:2).isEmpty)
        check("disclosure distinguishes collapsed and expanded", EventStreamPresentationState(isDisclosable:true).description(role:role("AXRow","row"),contextKind:0) == "(collapsed)" && EventStreamPresentationState(isDisclosable:true,isDisclosing:true).description(role:role("AXRow","row"),contextKind:0) == "(expanded)")
        check("string value settable state omits its type", EventStreamPresentationState(valueTypeDescription:"string",isValueSettable:true).description(role:role("AXTextArea","text area"),contextKind:0) == "(settable)")
        check("nonstring settable type remains literal", EventStreamPresentationState(valueTypeDescription:"number",isValueSettable:true).description(role:role("AXSlider","slider"),contextKind:0) == "(settable, number)")
        check("missing value type never invents settable state", EventStreamPresentationState(isValueSettable:true).description(role:role("AXTextField","text field"),contextKind:0).isEmpty)
        check("read-only type never advertises settable state", EventStreamPresentationState(valueTypeDescription:"string").description(role:role("AXTextField","text field"),contextKind:0).isEmpty)
        let state = EventStreamPresentationState(isSelectable:true,isSelected:true,isEnabled:false,isDisclosable:true,isDisclosing:true,valueTypeDescription:"number",isValueSettable:true,isSentByMe:true)
        check("all state markers use fixed order and punctuation", state.description(role:role("AXRow","row"),contextKind:0) == "(selected, disabled, expanded, settable, number, sent by me)")
        check("context2 menus suppress attributes even with descriptive data", EventStreamPresentation(title:"Hidden").accessibilityDescription(role:role("AXMenu",nil),state:.init(),contextKind:2,hasDescriptiveAttributes:true) == "menu")
        check("context2 button attributes require provider descriptive flag", EventStreamPresentation(placeholder:"Type").accessibilityDescription(role:role("AXButton","button"),state:.init(),contextKind:2,hasDescriptiveAttributes:false) == "button")
        check("context2 descriptive button attributes survive", EventStreamPresentation(title:"Open").accessibilityDescription(role:role("AXButton","button"),state:.init(),contextKind:2,hasDescriptiveAttributes:true) == "button Open")
        check("context2 nonbutton attributes do not require descriptive flag", EventStreamPresentation(title:"Article").accessibilityDescription(role:role("AXGenericElement",""),state:.init(),contextKind:2,hasDescriptiveAttributes:false) == "element Article")

        let button = EventStreamRenderNode(id:7,description:"button Open",detail:nil)
        let editor = EventStreamRenderNode(id:0,description:EventStreamPresentation(value:"á😀").accessibilityDescription(role:"text area",state:"(settable)"),detail:"editable")
        let forest = [EventStreamRenderNode(id:nil,description:"window",detail:nil,children:[button,editor]),.init(id:9,description:"menu bar",detail:nil)]
        let full = "window\n\t7 button Open\n\t0 text area (settable) á😀 editable\n9 menu bar"
        check("forest renders preorder with tab indentation and zero ID", EventStreamTreeRendering.description(forest,differenceLines:nil) == full)
        check("ID/detail options affect every node", EventStreamTreeRendering.lines(forest,options:[.withoutElementID,.withoutDetailText]) == ["window","\tbutton Open","\ttext area (settable) á😀","menu bar"])
        check("custom indent uses depth rather than a fixed prefix", EventStreamTreeRendering.lines(forest,indent:"·")[1] == "·7 button Open")
        check("present empty detail retains one separating space", EventStreamRenderNode(id:nil,description:"element",detail:"").line() == "element ")
        check("absent and negative IDs keep Int semantics", EventStreamRenderNode(id:-2,description:"element",detail:nil).line() == "-2 element" && EventStreamRenderNode(id:nil,description:"element",detail:nil).line() == "element")
        check("empty node text is still a line", EventStreamRenderNode(id:1,description:"",detail:nil).line() == "1 ")
        check("subtree difference options do not prune full trees", EventStreamTreeRendering.description(forest,differenceLines:nil,options:[.withoutInsertionSubtree,.withoutRemovalSubtree]) == full)
        check("unknown option bits do not hide text", button.line(options:.init(rawValue:128)) == "7 button Open")
        var deep = button
        for _ in 0..<40 { deep = .init(id:nil,description:"container",detail:nil,children:[deep]) }
        let deepLines = EventStreamTreeRendering.lines([deep])
        check("deep full trees have no automation indentation clamp", deepLines.count == 41 && deepLines.last == String(repeating:"\t",count:40)+"7 button Open")
        check("empty forest full fallback is not no_change", EventStreamTreeRendering.description([],differenceLines:nil).isEmpty)
        check("available empty diff uses exact no_change marker", EventStreamTreeRendering.description(forest,differenceLines:[]) == "no_change")
        check("available empty string line is not an empty diff", EventStreamTreeRendering.description(forest,differenceLines:[""]).isEmpty)
        check("available diff replaces full tree and uses LF without trailing LF", EventStreamTreeRendering.description(forest,differenceLines:["+ 8 button Save","- 7"]) == "+ 8 button Save\n- 7")
        check("available diff whitespace remains verbatim", EventStreamTreeRendering.description(forest,differenceLines:["  ","\t"]) == "  \n\t")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-rendering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let writer = try EventStreamJSONLWriter(sessionID:"rendered",rootDirectoryURL:root)
        try writer.append(.init(id:1,timestamp:Date(timeIntervalSince1970:0),kind:.windowChanged,ax:.init(mode:.fullTree,text:full)))
        try writer.append(.init(id:2,timestamp:Date(timeIntervalSince1970:1),kind:.windowChanged,ax:.init(mode:.diffFromPrevious,text:EventStreamTreeRendering.description(forest,differenceLines:[]))))
        writer.close()
        let physicalLines = try String(contentsOf:writer.eventsURL,encoding:.utf8).split(separator:"\n")
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let stored = try physicalLines.map { try decoder.decode(EventStreamRecord.self,from:Data($0.utf8)) }
        check("multiline tree and Unicode survive real JSONL round trip", physicalLines.count == 2 && stored[0].ax?.text == full)
        check("empty-diff marker retains recorded diff mode", stored[1].ax == .init(mode:.diffFromPrevious,text:"no_change"))
        print("EVENT STREAM RENDERING: \(checks) checks passed")
    }
}
