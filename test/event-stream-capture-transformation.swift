import Foundation

@main enum CaptureTransformationTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Tree=EventStreamCollectedTree<Int>
    enum Failure:Error {case expected}
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func context(_ limit:Int?=4000)->EventStreamMacTransformationContext {
        .init(type:.eventStreamContext,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:limit,includeQuery:true,includeFragment:true)))
    }
    static func item(_ id:Int,_ children:[Item]=[])->Item {
        var node=Node(element:id);node.value="source\(id)"
        return .init(node:node,path:[id],children:children,childrenSubset:nil)
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let url=URL(string:"https://example.test/a?q=1#part")!,stale=URL(string:"https://stale.test")!
        var main=Tree(roots:[item(1,[item(2)]),item(3)]),focus=Tree(roots:[item(4,[item(2)])])
        main.focusedElement=item(99).node;focus.focusedElement=item(98).node
        var c=context(),trace:[String]=[],transformCount=0
        _ = c.urlShortener.trim(url:stale,isImage:false)
        let output=EventStreamCaptureTransformation.run(main:main,focus:focus,context:&c,transform:{tree,current in
            transformCount += 1;trace.append("transform\(tree.roots[0].node.element)")
            if transformCount==1 {
                check("first transform sees freshly reset URL accounting",current.urlShortener.urls.isEmpty && current.urlShortener.accumulated==0)
                current.isChromium=true
            } else {check("focus transform sees main context changes",current.isChromium)}
            var tree=tree;tree.roots.append(item(10+transformCount));return tree
        },describe:{node,current in
            trace.append("describe\(node.element)");_ = current.urlShortener.trim(url:url,isImage:false);return ""
        },retrim:{_,_ in trace.append("unexpected trim")})
        check("transforms precede both preorder description walks",trace==["transform1","transform4","describe1","describe2","describe3","describe11","describe4","describe2","describe12"])
        check("all transformed nodes account even with empty descriptions",transformCount==2 && trace.filter {$0.hasPrefix("describe")}.count==7)
        check("main and focus can retain repeated source identities",output.main.preorder.map(\.node.element)==[1,2,3,11] && output.focus!.preorder.map(\.node.element)==[4,2,12])
        check("separate focused elements do not add accounting visits",!trace.contains("describe99") && !trace.contains("describe98"))
        check("unchanged configuration skips retrimming",!trace.contains("unexpected trim"))
        check("second reset clears preliminary discovery and counts",c.urlShortener.urls.isEmpty && c.urlShortener.accumulated==0 && c.urlShortener.domains.isEmpty)
        check("source values remain unchanged by transformed copies",main.roots.count==2 && focus.roots.count==1)
        check("context changes survive accounting and resets",c.isChromium)

        trace=[];c=context(nil)
        let empty=Tree(roots:[])
        let emptyPair=EventStreamCaptureTransformation.run(main:empty,focus:empty,context:&c,transform:{tree,_ in trace.append("transform");return tree},describe:{_,_ in fatalError("empty forest has no descriptions")},retrim:{tree,current in
            trace.append("trim");check("retrimming sees compacted default total limit",current.urlShortener.configuration.totalLimit==4000)
            check("retrimming retains empty captured forest",tree.roots.isEmpty)
        })
        check("present empty focus runs its own transform and retrim",trace==["transform","transform","trim","trim"] && emptyPair.focus != nil)
        check("compaction updates configuration even without discovered URLs",c.urlShortener.configuration.totalLimit==4000)
        trace=[];c=context(nil)
        let nilPair=EventStreamCaptureTransformation.run(main:empty,focus:nil,context:&c,transform:{tree,_ in trace.append("transform");return tree},describe:{_,_ in ""},retrim:{_,_ in trace.append("trim")})
        check("nil focus skips optional transform and retrim",trace==["transform","trim"] && nilPair.focus==nil)

        c=context(nil);trace=[]
        let budgetPair=EventStreamCaptureTransformation.run(main:Tree(roots:[item(1)]),focus:Tree(roots:[item(2)]),context:&c,transform:{tree,_ in tree},describe:{_,current in
            _ = current.urlShortener.trim(url:url,isImage:false);return "discarded"
        },retrim:{tree,current in
            trace.append("trim\(tree.roots[0].node.element)")
            if trace.count==1 {check("preliminary accounting is reset before first retrim",current.urlShortener.urls.isEmpty && current.urlShortener.accumulated==0)}
            else {check("focus retrim shares main retrim accounting",current.urlShortener.accumulated=="example.test/a?q=1#part".count)}
            _ = current.urlShortener.trim(url:url,isImage:false)
            tree.roots[0]=tree.roots[0].replacing(node:{var n=tree.roots[0].node;n.value="trimmed";return n}())
        })
        check("conditional retrimming runs main then focus",trace==["trim1","trim2"])
        check("both retrim results are retained",budgetPair.main.roots[0].node.value=="trimmed" && budgetPair.focus!.roots[0].node.value=="trimmed")
        check("there is no extra reset after retrimming",c.urlShortener.accumulated==2*"example.test/a?q=1#part".count && c.urlShortener.domains==["example.test":2])

        c=context();trace=[]
        _ = EventStreamCaptureTransformation.run(main:Tree(roots:[item(1)]),focus:nil,context:&c,transform:{tree,current in
            current.urlShortener.configuration.includeFragment=false;return tree
        },describe:{_,_ in ""},retrim:{_,_ in trace.append("trim")})
        check("configuration comparison uses value before transformations",trace==["trim"])
        let discoveredURLs=(0..<32).map {URL(string:"https://example.test/a?q=\($0)"+String(repeating:"x",count:50)+"#fragment")!}
        c=context(20);trace=[]
        _ = EventStreamCaptureTransformation.run(main:Tree(roots:[item(1)]),focus:nil,context:&c,transform:{tree,_ in tree},describe:{_,current in
            for url in discoveredURLs {_ = current.urlShortener.trim(url:url,isImage:false)};return ""
        },retrim:{_,current in trace.append(current.urlShortener.trim(url:discoveredURLs[0],isImage:false) ?? "nil")})
        check("all preliminary URLs participate in configuration compaction",!c.urlShortener.configuration.includeFragment && !c.urlShortener.configuration.includeQuery)
        check("retrimming uses the newly compacted configuration",trace==["example.test/a"])

        for failurePoint in ["main","focus","describe1","describe2","describe4"] {
            c=context(nil);trace=[];var caught=false
            do {
                _ = try EventStreamCaptureTransformation.run(main:main,focus:focus,context:&c,transform:{tree,current in
                    let point=tree.roots[0].node.element==1 ? "main":"focus";trace.append(point)
                    current.isCatalyst=true
                    if point==failurePoint {throw Failure.expected};return tree
                },describe:{node,current in
                    let point="describe\(node.element)";trace.append(point)
                    _ = current.urlShortener.trim(url:url,isImage:false)
                    if point==failurePoint {throw Failure.expected};return ""
                },retrim:{_,_ in fatalError("failure must stop before retrimming")})
            } catch Failure.expected {caught=true}
            check("failure at \(failurePoint) propagates before later phases",caught && trace.last==failurePoint)
            check("failure at \(failurePoint) preserves completed context effects",c.isCatalyst && c.urlShortener.configuration.totalLimit==nil)
            if failurePoint.hasPrefix("describe") {check("description failure keeps preliminary URL discovery",c.urlShortener.urls==[url] && c.urlShortener.accumulated>0)}
        }

        var rich=EventStreamTransformedString();rich.append(.url("old",url,isImage:false))
        var richNode=Node(element:1);richNode.transformedString=rich;richNode.value="plain"
        let richTree=Tree(roots:[.init(node:richNode,path:[],children:[],childrenSubset:nil)])
        c=context(nil)
        let retrimmed=EventStreamCaptureTransformation.run(main:richTree,focus:nil,context:&c,transform:{tree,_ in tree},describe:{node,current in
            for span in node.transformedString!.spans {if case let .url(_,url,isImage)=span {_ = current.urlShortener.trim(url:url,isImage:isImage)}};return ""
        },retrim:EventStreamTreeURLTrimming.trim)
        check("actual URL retrim worker updates returned plain and rich values",retrimmed.main.roots[0].node.value=="example.test/a?q=1#part" && retrimmed.main.roots[0].node.transformedString?.description=="example.test/a?q=1#part")
        check("actual URL retrim worker preserves raw input value",richTree.roots[0].node.value=="plain" && richTree.roots[0].node.transformedString?.description=="old")

        c=context(nil)
        let nativeEmpty=EventStreamCollectedTree<EventStreamAXNode>(roots:[])
        let native=try EventStreamNativeCaptureTransformation.run(main:nativeEmpty,focus:nativeEmpty,context:&c)
        check("native phase binding accepts present empty forests",native.main.roots.isEmpty && native.focus?.roots.isEmpty==true && c.urlShortener.configuration.totalLimit==4000)
        let root=try EventStreamNativeCaptureTransformation.revision(native,previous:nil,enableAXDiffing:true,context:&c)
        check("native revision binding roots when predecessor is absent",root.previousRevision==nil && root.focusRenderTree != nil)
        let next=try EventStreamNativeCaptureTransformation.revision(native,previous:root,enableAXDiffing:true,context:&c)
        check("native revision binding appends when diffing is enabled",next.previousRevision===root && next.lineageID==root.lineageID)
        let fresh=try EventStreamNativeCaptureTransformation.revision(native,previous:root,enableAXDiffing:false,context:&c)
        check("native revision binding roots when diffing is disabled",fresh.previousRevision==nil && fresh.lineageID != root.lineageID)
        print("EVENT STREAM CAPTURE TRANSFORMATION PHASES: \(checks) checks passed")
    }
}
