import Foundation
import ApplicationServices

@MainActor final class DriverMacBackend:EventStreamMacTransformationBackend {
    typealias Element=Int
    typealias Identity=Int
    var targets:[Int:[Int]]=[:]
    var bundles:[Int:String]=[:]
    func identity(_ element:Int)->Int {element}
    func titleTargets(_ element:Int)->[Int] {targets[element] ?? []}
    func title(for identity:Int)->String? {nil}
    func hasScrollBar(_ axis:EventStreamScrollAxis,of element:Int)->Bool {false}
    func applicationBundleIdentifier(of element:Int)->String? {bundles[element]}
}
@MainActor final class DriverAttributedBackend:EventStreamAttributedTextBackend {
    typealias Element=Int
    typealias Marker=Int
    typealias MarkerRange=NSRange
    var reads:[Int]=[]
    func textualContext(_ element:Int)->String? {nil}
    func supportsAttribute(_ name:String,of element:Int)->Bool {false}
    func parameterizedAttributes(_ element:Int)->Set<String> {[]}
    func captureElement(_ element:Int)->Int {element}
    func marker(_ name:String,of element:Int)->Int? {name==EventStreamAttributedTextAttributes.startMarker ? 0:3}
    func markerRangeForElement(_ element:Int,parameter:Int)throws->NSRange? {.init(location:0,length:3)}
    func nextLineEnd(_ marker:Int,of element:Int)throws->Int? {nil}
    func makeMarkerRange(start:Int,end:Int)throws->NSRange? {.init(location:start,length:end-start)}
    func attributedString(_ range:NSRange,of element:Int)throws->NSAttributedString? {
        reads.append(element);return .init(string:"new",attributes:[.init("AXStyleName"):"Title"])
    }
    func attributedString(_ range:NSRange,of element:Int,withOptions:Bool)throws->NSAttributedString? {try attributedString(range,of:element)}
}
@main @MainActor enum TreeTransformationTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Tree=EventStreamCollectedTree<Int>
    static var checks=0
    static func check(_ name:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(name)\n",stderr)}
        precondition(okay,name);checks += 1;print("PASS: \(name)")
    }
    static func item(_ id:Int,children:[Item]=[],edit:(inout Node)->Void={_ in})->Item {
        var n=Node(element:id);n.role="AXGroup";edit(&n)
        return .init(node:n,path:[id+100],children:children,childrenSubset:.init(count:50,availableRanges:[40..<41]))
    }
    static func context(_ type:EventStreamElementContextType = .fullUIContext)->EventStreamMacTransformationContext {
        .init(type:type,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
    }
    static func main() throws {
        setbuf(stdout,nil)
        let child=item(1,children:[item(3)]),second=item(2)
        let source=Tree(roots:[item(0,children:[child,second]),item(4)],duplicateReferencesSkipped:7,depthLimitedReferencesSkipped:9,focusedElement:item(99).node)
        var events:[String]=[],state=0
        let identity=EventStreamTreeTransformation.transform(source,using:["A","B"],context:&state) {pass,item,c in
            events.append("\(item.node.element):\(pass)");c += 1;return .unchanged
        }
        check("whole parent pipeline precedes children and preserves DFS sibling order",events==["0:A","0:B","1:A","1:B","3:A","3:B","2:A","2:B","4:A","4:B"])
        check("all passes share one mutable context",state==10)
        check("identity pipeline preserves topology",identity.preorder.map(\.node.element)==[0,1,3,2,4])
        check("pipeline preserves original paths and partial subsets",identity.preorder.map(\.path)==source.preorder.map(\.path) && identity.roots[0].childrenSubset==source.roots[0].childrenSubset)
        check("pipeline preserves independent focus even when outside items",identity.focusedElement?.element==99)
        check("collection diagnostics survive transformations",identity.duplicateReferencesSkipped==7 && identity.depthLimitedReferencesSkipped==9)
        events=[]
        let changed=EventStreamTreeTransformation.transform(Tree(roots:[item(0)]),using:[0,1,2],context:&state) {pass,current,_ in
            events.append("\(current.node.element):\(pass)")
            if pass==0 {var n=current.node;n.value="edited";return .transformed(current.replacing(node:n))}
            if pass==1 {check("next pass sees transformed item",current.node.value=="edited")}
            return .unchanged
        }
        check("transformed result continues at next pass without restarting",events==["0:0","0:1","0:2"] && changed.roots[0].node.value=="edited")
        events=[]
        let replaced=EventStreamTreeTransformation.transform(Tree(roots:[item(0,children:[item(7)])]),using:[0,1,2],context:&state) {pass,current,_ in
            events.append("\(current.node.element):\(pass)")
            if pass==1 && current.node.element==0 {return .replaced(item(8,children:[item(9)]))}
            return .unchanged
        }
        check("replacement restarts full pipeline before descending replacement children",events==["0:0","0:1","8:0","8:1","8:2","9:0","9:1","9:2"])
        check("replacement drops original descendants and keeps replacement metadata",replaced.preorder.map(\.node.element)==[8,9] && replaced.roots[0].path==[108])
        events=[]
        let removed=EventStreamTreeTransformation.transform(source,using:[0,1],context:&state) {pass,current,_ in
            events.append("\(current.node.element):\(pass)")
            return current.node.element==0 ? .removed:.unchanged
        }
        check("removed parent skips remaining passes and its entire subtree",events==["0:0","4:0","4:1"] && removed.preorder.map(\.node.element)==[4])
        check("removal does not clear independent focusedElement",removed.focusedElement?.element==99)
        let focusedNode=item(0) {$0.value="before"}.node
        let focusedChange=EventStreamTreeTransformation.transform(Tree(roots:[item(0)],focusedElement:focusedNode),using:[0],context:&state) {_,current,_ in
            var n=current.node;n.value="after";return .transformed(current.replacing(node:n))
        }
        check("focus is copied verbatim rather than refreshed from edited matching item",focusedChange.roots[0].node.value=="after" && focusedChange.focusedElement?.value=="before")
        var repeatedPasses=0
        _=EventStreamTreeTransformation.transform(Tree(roots:[item(0)]),using:[0,0],context:&repeatedPasses) {_,_,c in c += 1;return .unchanged}
        check("duplicate passes are applied separately in array order",repeatedPasses==2)
        let edits=EventStreamTreeTransformation.transform(Tree(roots:[item(0,children:[item(1)])]),using:[0],context:&state) {_,current,_ in
            current.node.element==0 ? .transformed(current.replacing(children:[item(2)])):.unchanged
        }
        check("descent uses changed child tree rather than original children",edits.preorder.map(\.node.element)==[0,2])
        var cached=source
        _=cached.hasDescendant(where:\.isFocusable)
        check("descendant property cache stores false",cached.descendantProperties[\.isFocusable]==false)
        _=cached.hasLeafDescendant(where:\.isSelected)
        _=cached.table(identity:{$0.element})
        check("recursive leaf query invalidates old parent cache and stores false",cached.descendantProperties.isEmpty && cached.leafProperties[\.isSelected]==false)
        let emptyPipeline=EventStreamTreeTransformation.transform(cached,using:[Int](),context:&state) {_,_,_ in preconditionFailure("empty pipeline")}
        check("empty pipeline rebuilds tree and clears property/table caches",emptyPipeline.descendantProperties.isEmpty && emptyPipeline.leafProperties.isEmpty && !emptyPipeline.hasCachedTable)
        check("input tree remains unchanged after transformation",cached.hasCachedTable && cached.focusedElement?.element==99 && cached.preorder.map(\.node.element)==source.preorder.map(\.node.element))
        var nested=Tree(roots:[item(1)],focusedElement:item(80).node)
        _=nested.hasDescendant(where:\.isEnabled);_=nested.table(identity:{$0.element})
        let nestedItem=Item(node:item(0).node,path:[4],subtree:nested,childrenSubset:nil)
        let nestedResult=EventStreamTreeTransformation.transform(Tree(roots:[nestedItem]),using:[0],context:&state) {_,i,_ in .unchanged}
        check("nested child tree focus survives recursive reconstruction",nestedResult.roots[0].subtree.focusedElement?.element==80)
        check("nested tree caches are cleared in output and retained in input",!nestedResult.roots[0].subtree.hasCachedTable && nestedItem.subtree.hasCachedTable)
        var n=nestedItem.node;n.title="edited"
        let nodeEdit=nestedItem.replacing(node:n)
        check("node-only edits preserve child tree caches and focus",nodeEdit.subtree.hasCachedTable && nodeEdit.subtree.focusedElement?.element==80)
        let childEdit=nestedItem.replacing(children:[])
        check("child-array mutation retains focus but invalidates caches",childEdit.subtree.focusedElement?.element==80 && !childEdit.subtree.hasCachedTable && childEdit.subtree.descendantProperties.isEmpty)
        var propertyTree=Tree(roots:[item(0,children:[item(1) {$0.isSelected=true}]) {$0.isFocusable=true}])
        check("descendant query includes root item properties",propertyTree.hasDescendant(where:\.isFocusable))
        check("leaf query excludes matching nonleaf root",!propertyTree.hasLeafDescendant(where:\.isFocusable))
        check("leaf query descends to actual matching leaf",propertyTree.hasLeafDescendant(where:\.isSelected))
        let propertyCopy=propertyTree
        propertyTree.roots=[]
        check("items setter invalidates both property caches and preserves copy",propertyTree.descendantProperties.isEmpty && propertyTree.leafProperties.isEmpty && !propertyCopy.leafProperties.isEmpty)
        check("empty-tree queries cache false",!propertyTree.hasDescendant(where:\.isEnabled) && !propertyTree.hasLeafDescendant(where:\.isEnabled) && propertyTree.descendantProperties[\.isEnabled]==false && propertyTree.leafProperties[\.isEnabled]==false)
        var tableTree=Tree(roots:[item(5,children:[item(7),item(8)]),item(5)])
        var calls=0
        let table=tableTree.table {node in calls += 1;return node.element}
        check("table IDs are preorder positions with last duplicate identity winning",table.values==[5:3,7:1,8:2] && table.elements==[3:5,1:7,2:8])
        check("table retains paths for every preorder position including duplicate gap",table.paths==[0:[0],1:[0,0],2:[0,1],3:[1]])
        check("table uses current array positions rather than source paths/subsets",table.paths[1]==[0,0] && tableTree.roots[0].children[0].path==[107])
        _=tableTree.table {node in calls += 1;return node.element}
        check("cached table avoids rereading identities",calls==4)
        let saved=tableTree
        tableTree.roots=[item(9)]
        check("items mutation invalidates cached table with value semantics",!tableTree.hasCachedTable && saved.hasCachedTable && tableTree.table(identity:{$0.element}).values==[9:0])
        var empty=Tree(roots:[])
        check("empty tree table is cached as a present empty value",empty.table(identity:{$0.element}).values.isEmpty && empty.hasCachedTable)
        var focused=tableTree;_=focused.table(identity:{$0.element});focused.focusedElement=item(200).node
        check("focus change does not invalidate item/property tables",focused.hasCachedTable && focused.focusedElement?.element==200)
        enum Failure:Error {case stop}
        var thrown=0
        do {
            _=try EventStreamTreeTransformation.transform(source,using:[0],context:&thrown) {_,_,c in c += 1;throw Failure.stop}
            check("callback failure propagates",false)
        } catch Failure.stop {check("callback failure preserves context edits and stops traversal",thrown==1)}

        let mac=DriverMacBackend(),attributed=DriverAttributedBackend()
        var ctx=context(.eventStreamContext)
        let text=item(10,children:[item(11) {$0.role="AXStaticText";$0.value="child"}]) {$0.role="AXTextArea";$0.value="old";$0.isFocusable=true}
        let actual=try EventStreamTreeTransformation.transformMac(Tree(roots:[text]),context:&ctx,backend:mac,attributed:attributed,format:{text,c in
            EventStreamAttributedMarkdown.format(text,shortener:&c.urlShortener) {_ in preconditionFailure("no links")}
        }) {_,_ in preconditionFailure("descriptive nodes do not render")}
        check("full Mac pipeline connects to the actual attributed writer",actual.roots.first?.node.value=="# new" && attributed.reads==[10])
        check("text-area children receive their own full pipeline",actual.roots[0].children.first?.node.value=="child")
        var sub=Tree(roots:[item(1)],focusedElement:item(80).node);_=sub.table(identity:{$0.element})
        let link=Item(node:{var n=item(20).node;n.role="AXLink";n.url=URL(string:"https://example.com");n.value="label";return n}(),path:[20],subtree:sub,childrenSubset:nil)
        let flattened=try EventStreamSharedTreeTransform.transform(link,pass:.flattenLinksIntoMarkdownText,shortener:&ctx.urlShortener)
        if case .transformed(let output)=flattened {
            check("link clear keeps nested focus while invalidating child cache",output.children.isEmpty && output.subtree.focusedElement?.element==80 && !output.subtree.hasCachedTable)
        } else {check("link clear keeps nested focus while invalidating child cache",false)}
        var fullContext=context()
        let filter=try EventStreamMacTreeTransform.transform(link,pass:.filterActions,context:&fullContext,backend:mac) {_,_ in ""}
        if case .transformed(let output)=filter {check("Mac action-only edit retains child tree cache",output.subtree.hasCachedTable && output.subtree.focusedElement?.element==80)}
        else {check("Mac action-only edit retains child tree cache",false)}
        func result(_ value:EventStreamTreeTransformationResult<Int>)->Item {
            guard case .transformed(let output)=value else {preconditionFailure("expected transformed result")};return output
        }
        var selectable=nestedItem.node;selectable.isSelectable=true
        let flat=try EventStreamSharedTreeTransform.transform(nestedItem.replacing(node:selectable),pass:.flattenIntoSelectableAncestor,context:&state) {_,_ in ""}
        check("selectable flatten retains independent subtree focus",result(flat).children.isEmpty && result(flat).subtree.focusedElement?.element==80 && !result(flat).subtree.hasCachedTable)
        var redundantSubtree=nested
        redundantSubtree.roots=[.init(node:item(1).node,path:[1],children:[],childrenSubset:nil)]
        _=redundantSubtree.table(identity:{$0.element})
        let redundant=try EventStreamSharedTreeTransform.transform(nestedItem.replacing(subtree:redundantSubtree),pass:.flattenRedundantHierarchy,context:&state) {_,_ in "same"}
        check("redundant flatten invalidates cache without discarding subtree focus",result(redundant).children.isEmpty && result(redundant).subtree.focusedElement?.element==80 && !result(redundant).subtree.hasCachedTable)
        var repeated=nestedItem.node;repeated.value="same"
        let repetitive=nestedItem.replacing(node:repeated,children:[item(1) {$0.value="same"}])
        let pruned=try EventStreamSharedTreeTransform.transform(repetitive,pass:.flattenRepetitiveStaticText,context:&state) {_,_ in ""}
        check("repetitive flatten retains subtree focus after splicing",result(pruned).children.isEmpty && result(pruned).subtree.focusedElement?.element==80)
        var targetTree=Tree(roots:[],focusedElement:item(90).node);_=targetTree.table(identity:{$0.element})
        let target=Item(node:item(2).node,path:[2],subtree:targetTree,childrenSubset:nil)
        let titleSource=item(1) {$0.role="AXStaticText";$0.title="copy"}
        mac.targets=[1:[2]]
        let titleItem=nestedItem.replacing(children:[titleSource,target])
        let titles=try EventStreamSharedTreeTransform.transform(titleItem,pass:.associateTitleUIElements,context:&state,titleAssociation:mac) {_,_ in ""}
        check("title copying retains target child cache and focus",result(titles).children[0].node.title=="copy" && result(titles).children[0].subtree.hasCachedTable && result(titles).children[0].subtree.focusedElement?.element==90 && result(titles).subtree.focusedElement?.element==80)
        let first=Item(node:{var n=item(1).node;n.role="AXStaticText";n.value="a";return n}(),path:[1],subtree:sub,childrenSubset:nil)
        let siblings=nestedItem.replacing(children:[first,item(2) {$0.role="AXStaticText";$0.value="b"}])
        let merged=try EventStreamSharedTreeTransform.transform(siblings,pass:.mergeTextOnlySiblings,contextType:.fullUIContext,shortener:&ctx.urlShortener)
        check("sibling merge retains parent and first nested focus",result(merged).subtree.focusedElement?.element==80 && result(merged).children[0].subtree.focusedElement?.element==80 && result(merged).children[0].children.isEmpty && !result(merged).children[0].subtree.hasCachedTable)
        var calendarNode=nestedItem.node;calendarNode.role="AXStaticText";calendarNode.roleDescription="Event"
        let calendar=nestedItem.replacing(node:calendarNode,children:[item(1) {$0.role="AXStaticText"}]);mac.bundles[0]="com.apple.iCal"
        let calendarResult=try EventStreamMacTreeTransform.transform(calendar,pass:.removeElementsUnderCalendarEvents,context:&fullContext,backend:mac) {_,_ in ""}
        check("Calendar clearing retains independent subtree focus",result(calendarResult).children.isEmpty && result(calendarResult).subtree.focusedElement?.element==80)
        var areaNode=nestedItem.node;areaNode.role="AXTextArea";areaNode.value="old"
        let areaItem=nestedItem.replacing(node:areaNode)
        let areaOutput=try EventStreamMacTreeTransform.transform(areaItem,pass:.retrieveAttributedTextFromTextAreas,context:&ctx,backend:mac,attributed:attributed,format:{text,_ in .init(text.string)}) {_,_ in ""}
        check("attributed TextArea node-only conversion retains subtree cache and focus",result(areaOutput).subtree.hasCachedTable && result(areaOutput).subtree.focusedElement?.element==80)
        areaNode.role="AXWebArea";ctx.type = .informationalContext
        let webOutput=try EventStreamMacTreeTransform.transform(nestedItem.replacing(node:areaNode),pass:.retrieveAttributedTextFromWebAreas,context:&ctx,backend:mac,attributed:attributed,format:{text,_ in .init(text.string)}) {_,_ in ""}
        check("attributed WebArea clearing retains focus and invalidates caches",result(webOutput).children.isEmpty && result(webOutput).subtree.focusedElement?.element==80 && !result(webOutput).subtree.hasCachedTable)
        print("Event-stream tree transformation: \(checks) checks passed")
    }
}
