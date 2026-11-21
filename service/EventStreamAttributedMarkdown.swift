import AppKit
import CoreText

//0x10078284C and the mapped trim/remove/replace helpers. Positions are UTF-16
// offsets into the acquired attributed string, independent of tree truncation.
struct EventStreamMappedText {
    private(set) var text:String
    private(set) var offsets:[Int?]
    init(_ text:String,offsets:[Int?]) {
        precondition(text.utf16.count==offsets.count)
        self.text=text;self.offsets=offsets
    }
    init(_ text:String,range:NSRange) {
        precondition(text.utf16.count==range.length)
        let end=range.location+range.length
        precondition(end>=range.location)
        self.init(text,offsets:(range.location..<end).map {Optional($0)})
    }
    static func unmapped(_ text:String)->Self {.init(text,offsets:Array(repeating:nil,count:text.utf16.count))}
    mutating func append(_ other:Self) {text += other.text;offsets += other.offsets}
    mutating func prepend(_ other:Self) {text=other.text+text;offsets=other.offsets+offsets}
    mutating func removeFirst() {
        guard !text.isEmpty else {return}
        offsets.removeFirst(String(text.removeFirst()).utf16.count)
    }
    mutating func removeLast() {
        guard !text.isEmpty else {return}
        offsets.removeLast(String(text.removeLast()).utf16.count)
    }
    func trimmed()->Self {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else {return .unmapped("")}
        let range=(text as NSString).range(of:trimmed)
        guard range.location != NSNotFound else {return .unmapped(trimmed)}
        return .init(trimmed,offsets:Array(offsets[range.location..<NSMaxRange(range)]))
    }
    func replacingLineFeeds(with replacement:Self)->Self {
        var result=Self.unmapped(""),position=0
        for character in text {
            let string=String(character),end=position+string.utf16.count
            result.append(character=="\n" ? replacement:.init(string,offsets:Array(offsets[position..<end])))
            position=end
        }
        return result
    }
}

struct EventStreamAttributedElementDescription {
    var role:String
    var url:URL?
    var description:String?
    var roleDescription:String?
}

enum EventStreamMarkdownStyle:Equatable {
    case heading(Int),blockQuote(Int),listItem(level:Int,index:Int,bullet:String)
    case codeBlock,collapsed,bold,italic,underline,strikethrough,superscript,subscriptStyle
    var isBlock:Bool {
        switch self {case .heading,.blockQuote,.listItem,.codeBlock,.collapsed:return true;default:return false}
    }
    //0x1007829E8: closing order is forward; structural openings prepend,
    // inline openings append. These are deliberately not balanced HTML rules.
    static func boundaries(closing:[Self],opening:[Self])->(close:String,open:String) {
        var close="",open=""
        for style in closing {
            switch style {
            case .heading,.blockQuote,.listItem:break
            case .codeBlock:close += "\n```"
            case .collapsed:close += "\n</summary>(collapsed content is hidden)</details>"
            case .bold:close += "**"
            case .italic:close += "*"
            case .underline:close += "</u>"
            case .strikethrough:close += "~~"
            case .superscript:close += "</sup>"
            case .subscriptStyle:close += "</sub>"
            }
        }
        for style in opening {
            switch style {
            case .heading(let level):open=String(repeating:"#",count:level)+" "+open
            case .blockQuote(let level):open=String(repeating:">",count:level)+" "+open
            case .listItem(let level,_,let bullet):open=String(repeating:" ",count:4*level)+bullet+" "+open
            case .codeBlock:open="```\n"+open
            case .collapsed:open="<details><summary>\n"+open
            case .bold:open += "**"
            case .italic:open += "*"
            case .underline:open += "<u>"
            case .strikethrough:open += "~~"
            case .superscript:open += "<sup>"
            case .subscriptStyle:open += "<sub>"
            }
        }
        return (close,open)
    }
}

@MainActor enum EventStreamAttributedMarkdown {
    typealias DescribeElement=(Any)->EventStreamAttributedElementDescription
    //0x10077ADA8 enumerates all runs with options0, then flushes empty attrs.
    static func format(_ attributed:NSAttributedString,shortener:inout EventStreamURLShortener,
                       describe:DescribeElement)->EventStreamTransformedString {
        var writer=Writer()
        attributed.enumerateAttributes(in:NSRange(location:0,length:attributed.length),options:[]) {attributes,range,_ in
            let text=EventStreamMappedText(attributed.attributedSubstring(from:range).string,range:range)
            writer.write(text,attributes:attributes,shortener:&shortener,describe:describe)
        }
        writer.write(.init("",range:NSRange(location:attributed.length,length:0)),attributes:[:],shortener:&shortener,describe:describe)
        return writer.markdown
    }

    @MainActor struct Writer {
        private(set) var markdown:EventStreamTransformedString=""
        private(set) var styleStack:[EventStreamMarkdownStyle]=[]
        mutating func write(_ input:EventStreamMappedText,attributes:[NSAttributedString.Key:Any],
                            shortener:inout EventStreamURLShortener,describe:DescribeElement) {
            var run=input,desired=styles(attributes)
            if let raw=attributes[.accessibilityLink] {
                let link=describe(raw)
                if let url=link.url,let display=shortener.trim(url:url,isImage:link.role=="AXImage") {
                    run=markdownLink(label:run.trimmed(),url:display,image:false)
                }
            }
            if let raw=attributes[.accessibilityAttachment] {
                let attachment=describe(raw)
                var candidate:EventStreamMappedText?,tail:EventStreamMappedText?
                if !run.text.isEmpty && run.text != "\u{fffc}" {
                    var hasNewline=false
                    for character in run.text {
                        // Native scalar conversion force-unwraps a single scalar.
                        let scalars=String(character).unicodeScalars
                        precondition(scalars.count==1)
                        if [10,11,12,13,133,8232,8233].contains(scalars.first!.value) {hasNewline=true;break}
                    }
                    if hasNewline {tail=run} else {candidate=run}
                }
                if attachment.role=="AXImage",let url=attachment.url,
                   let display=shortener.trim(url:url,isImage:true) {
                    run=markdownLink(label:(candidate ?? .unmapped(attachment.description ?? "")).trimmed(),url:display,image:true)
                } else {
                    var label=attachment.roleDescription ?? "attachment"
                    if let description=candidate?.text ?? attachment.description,!description.isEmpty {label += ": "+description}
                    run = .unmapped("["+label+"]")
                }
                if let tail {run.append(.unmapped(" "));run.append(tail)}
            }
            // Block/list styles come after the link and attachment rewrites.
            appendBlockStyles(attributes,to:&desired)
            let old=styleStack,closing=old.filter {!desired.contains($0)},opening=desired.filter {!old.contains($0)}
            styleStack.removeAll {closing.contains($0)};styleStack += opening
            if markdown.last=="\n" {markdown.removeLast();run.prepend(.unmapped("\n"))}
            let startsLine=run.text.first=="\n" && run.text.count>1
            if startsLine {run.removeFirst()}
            if desired.contains(where:{$0.isBlock}) {
                let all=EventStreamMarkdownStyle.boundaries(closing:desired,opening:desired)
                let endsLine=run.text.last=="\n"
                if endsLine {run.removeLast()}
                run=run.replacingLineFeeds(with:.unmapped(all.close+"\n"+all.open))
                if endsLine {run.append(.unmapped("\n"))}
                if startsLine {
                    let transition=EventStreamMarkdownStyle.boundaries(closing:old,opening:desired)
                    run.prepend(.unmapped(transition.close+"\n"+transition.open))
                    markdown.appendMappedString(run.text,sourceOffsets:run.offsets);return
                }
            }
            let transition=EventStreamMarkdownStyle.boundaries(closing:closing,opening:opening)
            if startsLine {run.prepend(.unmapped(transition.close+"\n"+transition.open))}
            else {markdown.append(transition.close+transition.open)}
            markdown.appendMappedString(run.text,sourceOffsets:run.offsets)
        }
    }

    private static func markdownLink(label:EventStreamMappedText,url:String,image:Bool)->EventStreamMappedText {
        var result=EventStreamMappedText.unmapped(image ? "![":"[")
        result.append(label);result.append(.unmapped("]("+url+")"));return result
    }
    private static func insert(_ style:EventStreamMarkdownStyle,into styles:inout [EventStreamMarkdownStyle]) {
        if !styles.contains(style) {styles.append(style)}
    }
    private static func styles(_ attributes:[NSAttributedString.Key:Any])->[EventStreamMarkdownStyle] {
        var result:[EventStreamMarkdownStyle]=[]
        if let font=attributes[.accessibilityFont] as? [String:Any] {
            if let name=font[NSAccessibility.FontAttributeKey.fontName.rawValue] as? String,
               let size=font[NSAccessibility.FontAttributeKey.fontSize.rawValue] as? Double {
                var attrs:[NSFontDescriptor.AttributeName:Any]=[.name:name]
                if let family=font[NSAccessibility.FontAttributeKey.fontFamily.rawValue] {attrs[.family]=family}
                if let resolved=NSFont(descriptor:NSFontDescriptor(fontAttributes:attrs),size:size) {
                    let traits=CTFontGetSymbolicTraits(resolved)
                    if traits.contains(.boldTrait) {insert(.bold,into:&result)}
                    if traits.contains(.italicTrait) {insert(.italic,into:&result)}
                }
            }
            if font["AXFontBold"] as? Bool == true {insert(.bold,into:&result)}
        }
        if let value=attributes[.accessibilityUnderline] as? NSNumber,value.intValue>=1 {insert(.underline,into:&result)}
        if let value=attributes[.accessibilityStrikethrough] as? NSNumber,value.boolValue {insert(.strikethrough,into:&result)}
        if let value=attributes[.accessibilitySuperscript] as? NSNumber {
            if value.intValue>0 {insert(.superscript,into:&result)}
            else if value.intValue<0 {insert(.subscriptStyle,into:&result)}
        }
        return result
    }
    private static func appendBlockStyles(_ attributes:[NSAttributedString.Key:Any],to result:inout [EventStreamMarkdownStyle]) {
        if let value=attributes[.init("AXBlockQuoteLevel")] as? NSNumber,value.intValue>=1 {insert(.blockQuote(value.intValue),into:&result)}
        if let names=attributes[.init("AXStyleName")] as? String {
            for name in names.components(separatedBy:", ") {
                switch name {
                case "Title":insert(.heading(1),into:&result)
                case "Heading":insert(.heading(2),into:&result)
                case "Subheading":insert(.heading(3),into:&result)
                case "Fixed width":insert(.codeBlock,into:&result)
                case "Collapsed":insert(.collapsed,into:&result)
                default:break
                }
            }
        }
        if let level=attributes[.accessibilityListItemLevel] as? NSNumber,
           let prefix=attributes[.accessibilityListItemPrefix] as? NSAttributedString,
           let index=attributes[.accessibilityListItemIndex] as? NSNumber {
            let bullet:String
            switch prefix.string {
            case "checklist item, incomplete":bullet="* [ ]"
            case "checklist item, completed":bullet="* [x]"
            default:bullet=prefix.string.first?.isNumber==true ? index.stringValue+".":"*"
            }
            insert(.listItem(level:level.intValue,index:index.intValue,bullet:bullet),into:&result)
        }
    }
}
