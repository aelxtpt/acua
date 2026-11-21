import Foundation

@main enum PruningTests {
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    static func node(_ edit:(inout Node)->Void = {_ in}) -> Node {
        var node=Node(element:1);node.role="AXGroup";edit(&node);return node
    }
    static func item(_ node:Node,children:[Item]=[],subset:EventStreamArraySubset?=nil) -> Item {
        .init(node:node,path:[7],children:children,childrenSubset:subset)
    }
    static func prune(_ item:Item,_ pass:EventStreamSharedTreeTransformation = .pruneNonDescriptiveSubtrees) -> Bool {
        (try! EventStreamTreePruning.decision(for:item,pass:pass)) == .removed
    }
    static func main() {
        setbuf(stdout,nil)
        check("shared default pipeline keeps nine raw values",EventStreamSharedTreeTransformation.defaultPipeline.map(\.rawValue)==Array(UInt8(0)...UInt8(8)))
        check("empty node has no descriptive attributes",!node().hasDescriptiveAttributes)
        check("native node counts whitespace as descriptive",node {$0.title=" \n\t"}.hasDescriptiveAttributes)
        check("tree item trims whitespace-only descriptions",!item(node {$0.title=" \n\t"}).hasDescriptiveAttributes)
        check("image role is descriptive without text",node {$0.role="AXImage"}.hasDescriptiveAttributes && item(node {$0.role="AXImage"}).hasDescriptiveAttributes)
        check("role matching is case sensitive",!node {$0.role="aximage"}.hasDescriptiveAttributes)
        check("nontext fields do not become descriptions",!node {$0.roleDescription="group";$0.help="help";$0.transformedString="transformed";$0.valueDescription="details";$0.identifier="id";$0.url=URL(string:"https://example.com")}.hasDescriptiveAttributes)
        for (label,key) in [("title",\Node.title),("description",\Node.description),("value",\Node.value),("placeholder",\Node.placeholderValue)] {
            let n=node {$0[keyPath:key]=" text "}
            check("\(label) describes native node",n.hasDescriptiveAttributes)
            check("\(label) describes descendant subtree",item(node(),children:[item(n)]).hasDescriptiveAttributes)
        }
        check("placeholder whitespace counts on node and is trimmed on item",node {$0.placeholderValue=" \n"}.hasDescriptiveAttributes && !item(node {$0.placeholderValue=" \n"}).hasDescriptiveAttributes)
        check("transformed text alone does not describe a subtree",!item(node {$0.transformedString="label"},children:[item(node {$0.transformedString="descendant"})]).hasDescriptiveAttributes)
        let tree=item(node {$0.title=" root "},children:[
            item(node {$0.title=" first "},children:[item(node {$0.title="\n nested\t"})]),
            item(node {$0.title=" \n"}),item(node {$0.title=" second "})])
        check("flattened text follows preorder and trims each value",tree.flattenedString(\.title)=="root\nfirst\nnested\nsecond")
        check("flattened values preserve embedded newlines and duplicates",item(node {$0.value="a\nb"},children:[item(node {$0.value="a\nb"})]).flattenedString(\.value)=="a\nb\na\nb")
        check("empty action list is not interesting",!node().hasInterestingActions)
        check("menu and scroll-to-visible actions are ignored",!node {$0.actionDescriptions=[.init(name:"AXShowMenu",description:"custom"),.init(name:"AXScrollToVisible",description:"custom"),.init(name:"AXShowMenu",description:"")]}.hasInterestingActions)
        check("press action remains interesting",node {$0.actionDescriptions=[.init(name:"AXPress",description:"")]}.hasInterestingActions)
        check("unknown action remains interesting despite familiar description",node {$0.actionDescriptions=[.init(name:"unknown",description:"Show Menu")]}.hasInterestingActions)
        check("interactive button ignores enabled flag",node {$0.role="AXButton";$0.isEnabled=false}.canBeUserInteractive)
        check("static text without focus or selection is not interactive",!node {$0.role="AXStaticText"}.canBeUserInteractive)
        check("focused static text alone is not focusable",!node {$0.role="AXStaticText";$0.isFocused=true}.canBeUserInteractive)
        check("focusable static text is interactive",node {$0.role="AXStaticText";$0.isFocusable=true}.canBeUserInteractive)
        check("selectable static text is interactive",node {$0.role="AXStaticText";$0.isSelectable=true}.canBeUserInteractive)
        check("focusable group is interactive",node {$0.isFocusable=true}.canBeUserInteractive)
        check("selectable group alone is not interactive",!node {$0.isSelectable=true}.canBeUserInteractive)
        check("focusable text area is interactive",node {$0.role="AXTextArea";$0.isFocusable=true}.canBeUserInteractive)
        check("selectable editable text area without focusability is not interactive",!node {$0.role="AXTextArea";$0.isSelectable=true;$0.isValueSettable=true}.canBeUserInteractive)
        check("unknown role follows ordinary interactive branch",node {$0.role="AXUnknown"}.canBeUserInteractive)
        check("non-descriptive subtree is removed even when enabled",prune(item(node())))
        check("focusable empty node survives subtree pruning",!prune(item(node {$0.isFocusable=true})))
        check("selectable empty node survives subtree pruning",!prune(item(node {$0.isSelectable=true})))
        check("focus without focusability does not save non-descriptive subtree",prune(item(node {$0.isFocused=true})))
        check("value settability alone does not save non-descriptive subtree",prune(item(node {$0.isValueSettable=true})))
        check("interesting root action saves subtree",!prune(item(node {$0.actionDescriptions=[.init(name:"AXPress",description:"")]})))
        check("menu-only root does not save subtree",prune(item(node {$0.actionDescriptions=[.init(name:"AXShowMenu",description:"")]})))
        let protected=item(node(),children:[item(node(),children:[item(node {$0.isFocusable=true})])])
        check("deep focusable descendant saves its ancestors",!prune(protected))
        let actionLeaf=item(node {$0.actionDescriptions=[.init(name:"SAIExpand",description:"")]})
        check("deep interesting action saves ancestors",!prune(item(node(),children:[item(node(),children:[actionLeaf])])))
        check("descendant selection protects subtree even when disabled",!prune(item(node(),children:[item(node {$0.isSelectable=true;$0.isEnabled=false})])))
        check("descendant whitespace and ignored actions do not save subtree",prune(item(node(),children:[item(node {$0.title=" \n";$0.actionDescriptions=[.init(name:"AXScrollToVisible",description:"")]})])))
        check("descendant image alone does not describe parent",prune(item(node(),children:[item(node {$0.role="AXImage"})])))
        check("image root survives subtree pruning",!prune(item(node {$0.role="AXImage"})))
        let disabled=node {$0.isEnabled=false}
        check("disabled empty leaf is removed",prune(item(disabled),.pruneEmptyDisabledElements))
        check("enabled empty leaf survives disabled pass",!prune(item(node()),.pruneEmptyDisabledElements))
        check("focused disabled empty leaf survives disabled pass",!prune(item(node {$0.isEnabled=false;$0.isFocused=true}),.pruneEmptyDisabledElements))
        check("selectable disabled empty leaf is still removed",prune(item(node {$0.isEnabled=false;$0.isSelectable=true}),.pruneEmptyDisabledElements))
        check("action-only disabled empty leaf is still removed",prune(item(node {$0.isEnabled=false;$0.actionDescriptions=[.init(name:"AXPress",description:"")]}),.pruneEmptyDisabledElements))
        check("disabled leaf with whitespace text is removed",prune(item(node {$0.isEnabled=false;$0.value=" \n"}),.pruneEmptyDisabledElements))
        check("disabled leaf with text survives",!prune(item(node {$0.isEnabled=false;$0.value="value"}),.pruneEmptyDisabledElements))
        check("disabled image leaf survives",!prune(item(node {$0.isEnabled=false;$0.role="AXImage"}),.pruneEmptyDisabledElements))
        check("disabled parent survives while any child remains",!prune(item(disabled,children:[item(disabled)]),.pruneEmptyDisabledElements))
        check("unavailable partial children do not count as actual children",prune(item(disabled,subset:.init(count:1000,availableRanges:[0..<0])),.pruneEmptyDisabledElements))
        check("pruning decisions leave source path and subset intact",tree.path==[7] && tree.children.count==3 && tree.flattenedString(\.title)=="root\nfirst\nnested\nsecond")
        var deep=item(node {$0.title="leaf"})
        for _ in 0..<200 {deep=item(node(),children:[deep])}
        check("maximum depth retains descendant text",!prune(deep) && deep.flattenedString(\.title)=="leaf")
        for pass in EventStreamSharedTreeTransformation.allCases where pass != .pruneNonDescriptiveSubtrees && pass != .pruneEmptyDisabledElements {
            do {_ = try EventStreamTreePruning.decision(for:tree,pass:pass);check("\(pass) must reject unsupported pass",false)}
            catch {check("\(pass) rejects unsupported pass explicitly",error as? EventStreamTreePruningError == .unsupportedTransformation(pass))}
        }
        print("Event-stream pruning: \(checks) checks passed")
    }
}
