import Foundation

@main enum TextSiblingTests {
    typealias Text=EventStreamTransformedString
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Result=EventStreamTreeTransformationResult<Int>
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int,_ value:String?=nil,_ role:String="AXStaticText",_ edit:(inout Node)->Void = {_ in})->Node {
        var n=Node(element:id);n.role=role;n.value=value;edit(&n);return n
    }
    static func item(_ n:Node,_ children:[Item]=[],_ subset:EventStreamArraySubset?=nil)->Item {
        .init(node:n,path:[n.element],children:children,childrenSubset:subset)
    }
    static func transformed(_ result:Result)->Item? {if case .transformed(let x)=result {return x};return nil}
    static func main() {
        setbuf(stdout,nil)
        let url=URL(string:"https://www.example.com/a")!
        check("context raw values follow the enum order",EventStreamElementContextType.allCases.map(\.rawValue)==[0,1,2])
        check("native flattened role table preserves distinct separators and target descriptions",
              EventStreamFlattenedRole.native(for:"AXStaticText") == .init(separator:" ",description:"text",targetDescription:"text")
              && EventStreamFlattenedRole.native(for:"AXRadioButton") == .init(separator:"; ",description:"radio button",targetDescription:"radio buttons")
              && EventStreamFlattenedRole.native(for:"AXRow") == .init(separator:"; ",description:"outline row",targetDescription:"rows")
              && EventStreamFlattenedRole.native(for:"AXLink")==nil)
        var first=Text();first.append(.url("first",url,isImage:false))
        var second=Text();second.append(.url("second",url,isImage:true))
        var joined=Text.joined([first,second],separator:" ")
        check("join preserves only first part rich URL metadata",joined.spans == [.url("first",url,isImage:false),.string(" second")])
        first = .init();first.appendMappedString("a",sourceOffsets:[7]);second = .init();second.appendMappedString("b",sourceOffsets:[8])
        joined=Text.joined([first,second],separator:";")
        check("join discards later source maps while nil-padding their displayed text",joined.description=="a;b" && joined.sourceOffsets==[7,nil,nil])
        check("join of no parts retains empty literal span",Text.joined([],separator:" ").spans == [.string("")])
        let emptyURL=Text.joined([Text(""),Text()],separator:" ")
        check("structurally empty part is replaced without separator",emptyURL.spans.isEmpty)
        var oneEmpty=Text();oneEmpty.append(.url("",url,isImage:true))
        check("single empty URL span is replaceable by next part",Text.joined([oneEmpty,Text("a")],separator:" ").spans == [.string("a")])
        oneEmpty.append(.url("",url,isImage:false))
        check("multiple empty spans retain structure and add separator",Text.joined([oneEmpty,Text("a")],separator:" ").spans == [.url("",url,isImage:true),.url("",url,isImage:false),.string(" a")])
        let subset=EventStreamArraySubset(count:100,availableRanges:[20..<22])
        let a=item(node(1,"a") {$0.title="first title";$0.identifier="first";$0.description="desc";$0.url=url},[item(node(11,"nested"))],subset)
        let b=item(node(2,"b"),[item(node(22,"discarded nested"))])
        func root(_ children:[Item],_ edit:(inout Node)->Void = {_ in})->Item {item(node(0,"parent","AXGroup",edit),children,subset)}
        var shortener=EventStreamURLShortener(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
        func run(_ tree:Item,_ context:EventStreamElementContextType = .eventStreamContext)->Result {
            try! EventStreamSharedTreeTransform.transform(tree,pass:.mergeTextOnlySiblings,contextType:context,shortener:&shortener)
        }
        var result=transformed(run(root([a,b])))!
        check("adjacent static text siblings merge with native separator",result.children.count==1 && result.children[0].node.value=="a b" && result.children[0].node.roleDescription=="text")
        check("merged child keeps first identity fields URL and source path",result.children[0].node.element==1 && result.children[0].path==[1] && result.children[0].node.title=="first title" && result.children[0].node.identifier=="first" && result.children[0].node.url==url)
        check("merge clears first child descendants and keeps both subset descriptors",result.children[0].children.isEmpty && result.children[0].childrenSubset==subset && result.childrenSubset==subset)
        check("parent node fields and input children remain unchanged",result.node.value=="parent" && a.children.count==1 && b.children.count==1)
        let separator=item(node(4,nil,"AXButton"))
        result=transformed(run(root([a,b,separator,item(node(5,"c")),item(node(6,"d"))])))!
        check("disjoint runs merge right-to-left without shifting intervening nodes",result.children.map(\.node.element)==[1,4,5] && result.children.map(\.node.value)==["a b",nil,"c d"])
        check("no eligible text returns unchanged",run(root([separator])).rawTag==3)
        check("empty child list returns unchanged",run(root([])).rawTag==3)
        result=transformed(run(root([a,separator,b])))!
        check("singleton runs return transformed without merging",result.children.map(\.node.element)==[1,4,2])
        check("parent selection/focusability guards precede candidate extraction",run(root([a,b]) {$0.isSelectable=true}).rawTag==3 && run(root([a,b]) {$0.isFocusable=true}).rawTag==3)
        check("effective focus and own text do not block sibling merge",transformed(run(root([a,b]) {$0.isFocused=true;$0.title="parent title"}))?.children.count==1)
        result=transformed(run(root([item(node(1,"a") {$0.isSelectable=true;$0.isFocusable=true}),b])))!
        check("child capabilities do not block eligible text merge",result.children.count==1 && result.children[0].node.isSelectable && result.children[0].node.isFocusable)
        check("nil stringValue splits text runs",transformed(run(root([a,item(node(3)),b])))?.children.map(\.node.element)==[1,3,2])
        check("captured boolean-convertible value splits text runs",transformed(run(root([a,item(node(3,"1") {$0.capturedValueIsBooleanConvertible=true}),b])))?.children.map(\.node.element)==[1,3,2])
        result=transformed(run(root([item(node(3,"")),a,b])))!
        check("empty first text is eligible and retains identity after filtering",result.children.count==1 && result.children[0].node.element==3 && result.children[0].node.value=="a b")
        result=transformed(run(root([item(node(3," \n")),item(node(4,"\t"))])))!
        check("all-whitespace run becomes one empty text item",result.children.count==1 && result.children[0].node.value=="" && result.children[0].node.transformedString?.spans == [.string("")])
        check("nonempty content is filtered but not trimmed",transformed(run(root([item(node(1," a ")),item(node(2," b "))])))?.children[0].node.value==" a   b ")
        let link=item(node(3,nil,"AXLink") {$0.url=url;$0.title="label"})
        for context in [EventStreamElementContextType.fullUIContext,.eventStreamContext] {
            let before=shortener.accumulated
            check("\(context) link splits text runs without URL work",transformed(run(root([a,link,b]),context))?.children.count==3 && shortener.accumulated==before)
        }
        let before=shortener.accumulated
        result=transformed(run(root([a,link,b]),.informationalContext))!
        check("informational links participate as Markdown",result.children.count==1 && result.children[0].node.value=="a [label](example.com/a) b")
        check("informational link formatting is cached once left-to-right",shortener.accumulated==before+"example.com/a".count)
        check("later link URL spans flatten into plain merged text",result.children[0].node.transformedString?.spans == [.string("a [label](example.com/a) b")])
        result=transformed(run(root([link,a,b]),.informationalContext))!
        check("run starting with link has no native flattened role and stays intact",result.children.map(\.node.element)==[3,1,2])
        let missing=item(node(7,nil,"AXLink") {$0.title="ignored without URL"})
        check("informational link without URL is an empty eligible bridge",transformed(run(root([a,missing,b]),.informationalContext))?.children[0].node.value=="a b")
        let prior=shortener.accumulated
        check("guarded parent never evaluates informational links",run(root([a,link]) {$0.isFocusable=true},.informationalContext).rawTag==3 && shortener.accumulated==prior)
        let pair=transformed(run(root([a,link]),.informationalContext))!
        check("merged value retains native first-child stringValue projection",pair.children[0].node.stringValue==pair.children[0].node.value)
        do {_ = try EventStreamSharedTreeTransform.transform(root([a,b]),pass:.associateTitleUIElements,contextType:.informationalContext,shortener:&shortener);check("unsupported pass rejected",false)}
        catch {check("text-context overload rejects unsupported passes explicitly",error as? EventStreamTreePruningError == .unsupportedTransformation(.associateTitleUIElements))}
        print("Event-stream text siblings: \(checks) checks passed")
    }
}
