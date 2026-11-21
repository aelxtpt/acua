import Foundation

@main enum EventStreamTreeURLTrimmingTests {
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func main() {
        setbuf(stdout,nil)
        typealias Tree=EventStreamCollectedTree<Int>
        typealias Item=EventStreamCollectedItem<Int>
        let a=URL(string:"https://www.example.test/a?x=1#part")!,b=URL(string:"https://example.test/b")!
        func context(_ type:EventStreamElementContextType = .eventStreamContext,_ limit:Int?=nil)->EventStreamMacTransformationContext {
            .init(type:type,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:limit,includeQuery:false,includeFragment:false)))
        }
        func item(_ id:Int,_ rich:EventStreamTransformedString?=nil,_ value:String?="plain",_ children:[Item]=[])->Item {
            var node=EventStreamTransformedNode(element:id);node.transformedString=rich;node.value=value
            return .init(node:node,path:[id],children:children,childrenSubset:.init(count:99,availableRanges:[1..<2]))
        }
        func rich(_ url:URL,_ text:String="old",image:Bool=false)->EventStreamTransformedString {
            var r=EventStreamTransformedString();r.append(.url(text,url,isImage:image));return r
        }
        var c=context(),empty=Tree(roots:[])
        _ = empty.table(identity:{$0.element});_ = empty.hasDescendant(where:\.isFocused)
        EventStreamTreeURLTrimming.trim(&empty,context:&c)
        check("empty tree preserves table and predicate caches",empty.hasCachedTable && empty.descendantProperties[\.isFocused]==false)
        check("empty tree leaves URL accounting untouched",c.urlShortener.urls.isEmpty && c.urlShortener.accumulated==0)
        var nested=Tree(roots:[],focusedElement:item(80,rich(a)).node)
        _ = nested.table(identity:{$0.element});_ = nested.hasDescendant(where:\.isFocused)
        var root=item(1);root=root.replacing(subtree:nested)
        var tree=Tree(roots:[root],focusedElement:item(90,rich(a)).node)
        _ = tree.table(identity:{$0.element});_ = tree.hasDescendant(where:\.isFocused)
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("nonempty tree clears caches even without rich text",!tree.hasCachedTable && tree.descendantProperties.isEmpty)
        check("untouched empty child tree keeps its own caches",tree.roots[0].subtree.hasCachedTable && tree.roots[0].subtree.descendantProperties[\.isFocused]==false)
        check("root independent focus is never URL-trimmed",tree.focusedElement?.transformedString?.description=="old")
        check("nested independent focus is also retained",tree.roots[0].subtree.focusedElement?.transformedString?.description=="old")
        check("focus-only URLs do not enter accounting",c.urlShortener.urls.isEmpty)
        tree=Tree(roots:[item(1,rich(a))]);let original=tree;c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("changed rich URL updates ordinary plain value",tree.roots[0].node.value=="example.test/a")
        check("changed rich representation is retained",tree.roots[0].node.transformedString?.description=="example.test/a")
        check("source tree retains old rich and plain values",original.roots[0].node.transformedString?.description=="old" && original.roots[0].node.value=="plain")
        check("native source path and child subset survive trimming",tree.roots[0].path==[1] && tree.roots[0].childrenSubset==original.roots[0].childrenSubset)
        check("worker updates context discovery and domains",c.urlShortener.urls==[a] && c.urlShortener.domains==["example.test":1])
        tree=Tree(roots:[item(1,rich(a,"example.test/a"),"intentionally stale")]);c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("unchanged rich URL does not regenerate plain value",tree.roots[0].node.value=="intentionally stale")
        check("unchanged rich URL still consumes context budget",c.urlShortener.accumulated=="example.test/a".count)
        let attributed=NSAttributedString(string:"source")
        var n=item(1,rich(a),"attributed plain").node;n.attributedString=attributed
        tree=Tree(roots:[.init(node:n,path:[],children:[],childrenSubset:nil)]);c=context(.informationalContext)
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("informational attributed node keeps original plain value",tree.roots[0].node.value=="attributed plain")
        check("informational attributed node still changes rich URL",tree.roots[0].node.transformedString?.description=="example.test/a")
        check("attributed source object is retained without reformatting",tree.roots[0].node.attributedString === attributed)
        c=context(.fullUIContext);tree=Tree(roots:[.init(node:n,path:[],children:[],childrenSubset:nil)])
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("full context attributed node updates plain value",tree.roots[0].node.value=="example.test/a")
        c=context(.informationalContext);tree=Tree(roots:[item(1,rich(a),nil)])
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("informational node without attributed source updates nil plain value",tree.roots[0].node.value=="example.test/a")
        var mapped=EventStreamTransformedString();mapped.appendMappedString("😀",sourceOffsets:[10,11]);mapped.append(.url("old",a,isImage:false))
        tree=Tree(roots:[item(1,mapped)]);c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("changed URL keeps the UTF-16 source map verbatim",tree.roots[0].node.transformedString?.sourceOffsets==[10,11,nil,nil,nil])
        check("stale-map behavior remains visible after length change",tree.roots[0].node.transformedString!.description.utf16.count != tree.roots[0].node.transformedString!.sourceOffsets!.count)
        tree=Tree(roots:[item(1,rich(a),"parent",[item(2,rich(b),"child")]),item(3,rich(a),"sibling")]);c=context(.eventStreamContext,"example.test/a".count)
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("trimming consumes budget parent before child before sibling",tree.preorder.map(\.node.value)==["example.test/a","…","…"])
        check("duplicate URL spans consume budget independently",c.urlShortener.accumulated=="example.test/a".count+2 && c.urlShortener.domains["example.test"]==3)
        check("worker retains URL configuration without reset or compaction",c.urlShortener.configuration == .init(individualLimit:nil,totalLimit:"example.test/a".count,includeQuery:false,includeFragment:false))
        tree=Tree(roots:[item(1,rich(a,"image label",image:true))]);c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("image rejection replaces display text with empty string",tree.roots[0].node.value=="" && tree.roots[0].node.transformedString?.description=="")
        check("rejected image discovery consumes no URL budget",c.urlShortener.urls==[a] && c.urlShortener.accumulated==0)
        tree=Tree(roots:[item(1,rich(a,""))]);c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("empty URL display can be restored under a new configuration",tree.roots[0].node.value=="example.test/a")
        tree=Tree(roots:[item(1,EventStreamTransformedString("literal"),"different")]);c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("rich text without URL leaves plain value unchanged",tree.roots[0].node.value=="different" && c.urlShortener.urls.isEmpty)
        var selected=item(1,rich(a)).node;selected.capturedValueIsBooleanConvertible=true;selected.truncationRange = .init(location:3,length:8)
        tree=Tree(roots:[.init(node:selected,path:[],children:[],childrenSubset:nil)]);c=context()
        EventStreamTreeURLTrimming.trim(&tree,context:&c)
        check("trimming retains Boolean projection and truncation metadata",tree.roots[0].node.stringValue==nil && tree.roots[0].node.truncationRange==NSRange(location:3,length:8))
        print("EVENT STREAM TREE URL TRIMMING: \(checks) checks passed")
    }
}
