import Foundation

@main enum MarkdownLinkTests {
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func make()->EventStreamURLShortener {.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))}
    static func main() {
        setbuf(stdout,nil)
        let url=URL(string:"https://www.example.com/a")!,display="example.com/a"
        var s=make(),text=EventStreamTransformedString()
        text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"value",title:"title",description:"desc",shortener:&s)
        check("link labels prefer string value",text.description=="[value](\(display))")
        check("link retains URL span with original URL",text.spans == [.string("[value]("),.url(display,url,isImage:false),.string(")")])
        check("link uses one URL budget evaluation",s.accumulated==display.count && s.domains==["example.com":1])
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"",title:"title",description:"desc",shortener:&s)
        check("empty string value falls through to title",text.description=="[title](\(display))")
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:nil,title:"",description:"desc",shortener:&s)
        check("empty title falls through to description",text.description=="[desc](\(display))")
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:nil,title:nil,description:nil,shortener:&s)
        check("missing label produces autolink syntax",text.description=="<\(display)>")
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:" \n\t",title:"fallback",description:nil,shortener:&s)
        check("whitespace raw value wins before trimming",text.description=="[](\(display))")
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:" [a]\\*\n ",title:nil,description:nil,shortener:&s)
        check("label escapes only square brackets and trims its ends",text.description=="[\\[a\\]\\*](\(display))")
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"a\nb",title:nil,description:nil,shortener:&s)
        check("internal label newlines are retained",text.description=="[a\nb](\(display))")
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"[\u{301}]",title:nil,description:nil,shortener:&s)
        check("escaping matches whole Characters at combining-mark boundaries",text.description=="[[\u{301}\\]](\(display))")
        let filtered=URL(string:"data:text/plain,body")!
        text = .init();text.appendMarkdownLink(url:filtered,role:"AXLink",stringValue:"label",title:nil,description:nil,shortener:&s)
        check("filtered display keeps empty URL span and original source",text.description=="[label]()" && text.spans == [.string("[label]("),.url("",filtered,isImage:false),.string(")")])
        text = .init();text.appendMarkdownLink(url:filtered,role:"AXLink",stringValue:nil,title:nil,description:nil,shortener:&s)
        check("filtered autolink preserves angle brackets",text.description=="<>")
        text = .init();text.appendURL(url,role:"AXImage",shortener:&s)
        check("image interpolation preserves metadata with empty display",text.spans == [.url("",url,isImage:true)] && text.description.isEmpty)
        text = .init();text.appendURL(url,role:nil,shortener:&s)
        check("nil role is ordinary URL interpolation",text.spans == [.url(display,url,isImage:false)])
        text = .init();text.appendMappedString("😀",sourceOffsets:[4,5]);text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"é",title:nil,description:nil,shortener:&s)
        check("Markdown append preserves prefix maps and nil-pads new UTF-16 text",text.sourceOffsets==[4,5]+Array<Int?>(repeating:nil,count:"[é](\(display))".utf16.count))
        s = .init(configuration:.init(individualLimit:nil,totalLimit:0,includeQuery:true,includeFragment:true))
        text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"label",title:nil,description:nil,shortener:&s)
        check("budget exhaustion remains a rich URL ellipsis",text.description=="[label](…)" && text.spans == [.string("[label]("),.url("…",url,isImage:false),.string(")")])
        s=make();text = .init();text.appendMarkdownLink(url:url,role:"AXLink",stringValue:"label",title:nil,description:nil,shortener:&s)
        check("same-budget retrim updates accounting even without display change",!text.trimURLs(shortener:&s) && s.accumulated==display.count*2 && s.domains["example.com"]==2)
        s.reset();s.configuration.individualLimit=3
        check("retrim uses preserved source URL with compacted configuration",text.trimURLs(shortener:&s) && text.description=="[label](ex…)" && s.urls==[url] && s.accumulated==3)
        print("Event-stream Markdown links: \(checks) checks passed")
    }
}
