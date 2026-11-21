import Foundation

@main enum LinkTransformTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func main() {
        setbuf(stdout,nil)
        let url=URL(string:"https://www.example.com/a")!,subset=EventStreamArraySubset(count:100,availableRanges:[50..<51])
        var node=Node(element:7);node.role="AXLink";node.url=url;node.title="title";node.value="value"
        node.isFocusable=true;node.isSelectable=true;node.isFocused=true;node.isEnabled=false
        node.description="description";node.placeholderValue="placeholder";node.identifier="id";node.attributedString=NSAttributedString(string:"attributed")
        let child=Item(node:Node(element:8),path:[2,4],children:[],childrenSubset:nil)
        func item(_ node:Node)->Item {.init(node:node,path:[2],children:[child],childrenSubset:subset)}
        var shortener=EventStreamURLShortener(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
        func transformed(_ n:Node)->Item? {
            let result=try! EventStreamSharedTreeTransform.transform(item(n),pass:.flattenLinksIntoMarkdownText,shortener:&shortener)
            if case .transformed(let i)=result {return i};return nil
        }
        let converted=transformed(node)!
        check("link becomes static text with link role description",converted.node.role=="AXStaticText" && converted.node.roleDescription=="link")
        check("value and rich transformed string contain Markdown",converted.node.value=="[value](example.com/a)" && converted.node.transformedString?.description==converted.node.value)
        check("converted link clears URL and loaded descendants",converted.node.url==nil && converted.children.isEmpty)
        check("converted link retains identity path and original subset",converted.node.element==7 && converted.path==[2] && converted.childrenSubset==subset)
        check("capabilities and disabled/focused states remain intact",converted.node.isFocusable && converted.node.isSelectable && converted.node.isFocused && !converted.node.isEnabled)
        check("other node fields are retained",converted.node.title=="title" && converted.node.description=="description" && converted.node.placeholderValue=="placeholder" && converted.node.identifier=="id" && converted.node.attributedString?.string=="attributed")
        check("source input is not mutated",node.role=="AXLink" && node.url==url && node.value=="value" && node.transformedString==nil)
        node.value=nil;node.title=nil;node.description=nil
        check("unlabeled link is transformed to autolink",transformed(node)?.node.value=="<example.com/a>")
        node.value="raw boolean";node.capturedValueIsBooleanConvertible=true;node.title="title"
        let boolean=transformed(node)!
        check("captured boolean suppression influences label priority and survives conversion",boolean.node.value=="[title](example.com/a)" && boolean.node.stringValue==nil)
        node.url=URL(string:"relative/path")!
        check("filtered relative URL still yields transformed Markdown",transformed(node)?.node.value=="[title]()")
        let count=shortener.accumulated,seen=shortener.urls
        node.url=nil
        check("missing URL returns unchanged without shortener access",transformed(node)==nil && shortener.accumulated==count && shortener.urls==seen)
        node.url=url;node.role="AXButton"
        check("non-link role returns unchanged without shortener access",transformed(node)==nil && shortener.accumulated==count && shortener.urls==seen)
        do {_ = try EventStreamSharedTreeTransform.transform(item(node),pass:.mergeTextOnlySiblings,shortener:&shortener);check("unsupported pass rejected",false)}
        catch {check("URL-only overload rejects unsupported passes explicitly",error as? EventStreamTreePruningError == .unsupportedTransformation(.mergeTextOnlySiblings))}
        print("Event-stream link transformation: \(checks) checks passed")
    }
}
