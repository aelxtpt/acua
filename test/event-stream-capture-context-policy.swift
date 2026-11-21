import Foundation

@main enum EventStreamCaptureContextPolicyTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Tree=EventStreamCollectedTree<Int>
    typealias Revision=EventStreamTreeRevision<Int,Int>
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()throws->Bool) {
        guard (try? result())==true else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int=0,role:String="AXStaticText",subrole:String?=nil,roleDescription:String?=nil,identifier:String?=nil)->Node {
        var n=Node(element:id);n.role=role;n.subrole=subrole;n.roleDescription=roleDescription;n.identifier=identifier;return n
    }
    static func tree(_ nodes:[Node])->Tree {.init(roots:nodes.map {.init(node:$0,path:[],children:[],childrenSubset:nil)})}
    static func pad(_ n:Node)->Tree {tree([n]+(1...9).map {node($0)})}
    @MainActor static func needed(_ tree:Tree,bundle:String?="fixture",size:CGSize?=nil,actions:[String]=[],force:Bool=false)->Bool {
        EventStreamScreenshotContextPolicy.needed(tree,alwaysIncludeScreenshot:force,bundleIdentifier:{bundle},uncachedSize:{_ in size},actionDescriptions:{_ in actions})
    }
    @MainActor static func revision(_ texts:[String],previous:Revision?=nil,ids:[Int]?=nil)throws->Revision {
        let roots=texts.enumerated().map {i,text in EventStreamRenderedNode(identity:ids?[i] ?? i,elementID:ids?[i] ?? i,text:text,sourcePath:[i])}
        return try .init(tree:.init(roots:[]),renderTree:.init(isFocusTree:false,roots:roots),lineageID:"lineage",previousRevision:previous,identity:{$0})
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let ordinary=tree((0..<10).map {node($0)}),image=node(role:"AXImage"),sticker=node(role:"AXButton",identifier:"Sticker")
        var reads:[String]=[]
        let forced=EventStreamScreenshotContextPolicy.needed(ordinary,alwaysIncludeScreenshot:true,bundleIdentifier:{reads.append("bundle");return "com.aex.computeruse"},uncachedSize:{_ in reads.append("size");return nil},actionDescriptions:{_ in reads.append("actions");return []})
        check("caller always-include override skips all policy reads",forced && reads.isEmpty)
        for bundle in ["com.aex.computeruse","com.aex.computeruse.client"] {
            check("own bundle exemption \(bundle)",!needed(tree([]),bundle:bundle,size:.init(width:200,height:200)))
        }
        check("bundle exemptions are case-sensitive",needed(tree([]),bundle:"COM.AEX.COMPUTERUSE"))
        check("a lookalike prefix is not exempt",needed(tree([]),bundle:"com.aex.computeruseextra"))
        check("other apps are not exempt",needed(tree([]),bundle:"com.example.agent"))
        check("empty tree requests screenshot for non-exempt app",needed(tree([])))
        check("nil bundle still applies small-tree rule",needed(tree([]),bundle:nil))
        check("nine loaded nodes request screenshot",needed(tree((0..<9).map {node($0)})))
        check("ten ordinary nodes do not request screenshot",!needed(ordinary))
        var sparse=Tree(roots:[.init(node:node(),path:[],children:[],childrenSubset:.init(count:5000,availableRanges:nil))],duplicateReferencesSkipped:5000)
        sparse.focusedElement=image
        check("small-tree count uses loaded nodes rather than subset metadata",needed(sparse))
        var independent=ordinary;independent.focusedElement=image
        check("independent focused element is excluded from raw count and image candidates",!needed(independent,size:.init(width:200,height:200)))
        for candidate in [image,node(roleDescription:"image"),node(subrole:"AXTextAttachment")] {
            check("image classification \(candidate.role)/\(candidate.roleDescription ?? "")/\(candidate.subrole ?? "")",needed(pad(candidate),size:.init(width:101,height:101)))
        }
        check("image description and subrole comparisons are exact",!needed(pad(node(subrole:"axtextattachment",roleDescription:"Image")),size:.init(width:200,height:200)))
        check("width exactly100 does not trigger screenshot",!needed(pad(image),size:.init(width:100,height:101)))
        check("height exactly100 does not trigger screenshot",!needed(pad(image),size:.init(width:101,height:100)))
        check("both dimensions must exceed100",needed(pad(image),size:.init(width:101,height:101)))
        check("missing fresh size skips candidate",!needed(pad(image)))
        check("negative dimensions do not trigger screenshot",!needed(pad(image),size:.init(width:-200,height:201)))
        check("NaN width and height retain ordered comparison semantics",!needed(pad(image),size:.init(width:CGFloat.nan,height:201)) && !needed(pad(image),size:.init(width:201,height:CGFloat.nan)))
        check("positive infinity has no invented finite-value rejection",needed(pad(image),size:.init(width:CGFloat.infinity,height:201)))
        reads=[]
        let duplicateImages=tree([image,image]+(1...8).map {node($0)})
        _=EventStreamScreenshotContextPolicy.needed(duplicateImages,bundleIdentifier:{reads.append("bundle");return nil},uncachedSize:{id in reads.append("size\(id)");return .zero},actionDescriptions:{_ in reads.append("actions");return []})
        check("image sizes are read per occurrence and bundle read repeats after images",reads==["bundle","size0","size0","bundle"])
        reads=[]
        let earlyImage=EventStreamScreenshotContextPolicy.needed(duplicateImages,bundleIdentifier:{reads.append("bundle");return "fixture"},uncachedSize:{_ in reads.append("size");return .init(width:101,height:101)},actionDescriptions:{_ in reads.append("actions");return []})
        check("first large image short-circuits later reads",earlyImage && reads==["bundle","size"])
        reads=[];var bundleCalls=0
        let changing=EventStreamScreenshotContextPolicy.needed(pad(sticker),bundleIdentifier:{bundleCalls += 1;return bundleCalls==1 ? nil:"com.apple.MobileSMS"},uncachedSize:{_ in reads.append("size");return nil},actionDescriptions:{_ in reads.append("actions");return ["Quick Look"]})
        check("Messages query is independent of initial bundle query",changing && bundleCalls==2 && reads==["actions"])
        check("Messages sticker Quick Look description requests screenshot",needed(pad(sticker),bundle:"com.apple.MobileSMS",actions:["Quick Look"]))
        check("Messages sticker Photos description requests screenshot",needed(pad(sticker),bundle:"com.apple.MobileSMS",actions:["Add to Photos Library"]))
        check("other app sticker does not invoke Messages behavior",!needed(pad(sticker),actions:["Quick Look"]))
        check("Messages bundle comparison is exact",!needed(pad(sticker),bundle:"COM.APPLE.MOBILESMS",actions:["Quick Look"]))
        check("Sticker identifier comparison is exact",!needed(pad(node(role:"AXButton",identifier:"sticker")),bundle:"com.apple.MobileSMS",actions:["Quick Look"]))
        check("Sticker identifier alone requires button role",!needed(pad(node(role:"AXStaticText",identifier:"Sticker")),bundle:"com.apple.MobileSMS",actions:["Quick Look"]))
        var titled=node(role:"AXButton");titled.title="Sticker"
        check("Sticker title does not substitute for identifier",!needed(pad(titled),bundle:"com.apple.MobileSMS",actions:["Quick Look"]))
        check("action descriptions are case-sensitive and not raw action names",!needed(pad(sticker),bundle:"com.apple.MobileSMS",actions:["quick look","AXQuickLook"]))
        var cached=sticker;cached.actionDescriptions=[.init(name:"AXCustom",description:"Quick Look")]
        check("cached transformed actions do not replace fresh actions",!needed(pad(cached),bundle:"com.apple.MobileSMS"))
        let first=node(10,role:"AXButton",identifier:"Sticker"),second=node(11,role:"AXButton",identifier:"Sticker")
        reads=[]
        let stickers=EventStreamScreenshotContextPolicy.needed(tree([first,second]+(1...8).map {node($0)}),bundleIdentifier:{"com.apple.MobileSMS"},uncachedSize:{_ in nil},actionDescriptions:{id in reads.append("actions\(id)");return id==10 ? []:["Quick Look"]})
        check("sticker candidates retain order and stop at first accepted description",stickers && reads==["actions10","actions11"])
        let root=try revision(["initial","keep"]),middle=try revision(["middle","keep"],previous:root),last=try revision(["initial","keep"],previous:middle)
        check("full selection description joins main render lines",last.eventStreamDescription(.fullTree,lineOptions:[],ignoreDifferenceLineBudget:false)=="0 initial\n1 keep")
        check("previous baseline compares immediate predecessor",last.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="~0 initial")
        check("initial baseline walks entire predecessor chain",last.eventStreamDescription(.difference(from:.initial),lineOptions:[],ignoreDifferenceLineBudget:false)=="no_change")
        check("root difference request falls back to full tree",root.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="0 initial\n1 keep")
        check("initial root request also falls back to full tree",root.eventStreamDescription(.difference(from:.initial),lineOptions:[],ignoreDifferenceLineBudget:false)=="0 initial\n1 keep")
        check("full serialization propagates line options",last.eventStreamDescription(.fullTree,lineOptions:[.withoutElementID],ignoreDifferenceLineBudget:false)=="initial\nkeep")
        let emptyRoot=try revision([]),emptyNext=try revision([],previous:emptyRoot)
        check("empty full tree remains empty string",emptyRoot.eventStreamDescription(.fullTree,lineOptions:[],ignoreDifferenceLineBudget:false).isEmpty)
        check("empty available difference is no_change",emptyNext.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="no_change")
        let shrink=try revision(["changed"],previous:root);var notices:[EventStreamDifferenceLineBudgetExceeded]=[]
        let fallback=shrink.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})
        check("unavailable difference falls back to full lines and preserves notice",fallback=="0 changed" && notices==[.removedElementSummary(1)])
        check("selection description always summarizes removed IDs",shrink.eventStreamDescription(.difference(from:.previous),lineOptions:[.withoutRemovalSubtree],ignoreDifferenceLineBudget:true)=="~0 changed\nRemoved element IDs: 1")
        let unchanged=try revision(["initial","keep"],previous:root)
        check("available empty previous difference returns no_change",unchanged.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="no_change")
        notices=[]
        _=shrink.eventStreamDescription(.fullTree,lineOptions:[],ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})
        check("full-tree mode does not invoke difference budget callback",notices.isEmpty)
        root.renderTree.roots[0].elementID=nil
        check("snapshot failure uses live full-tree fallback",middle.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="0 middle\n1 keep")
        root.renderTree.roots[0].elementID=0
        let beforeText=root.renderTree.roots[0].text;root.renderTree.roots[0].text="new initial"
        check("baseline rendering reads current revision references",last.eventStreamDescription(.difference(from:.initial),lineOptions:[],ignoreDifferenceLineBudget:false)=="~0 initial")
        root.renderTree.roots[0].text=beforeText
        print("EVENT STREAM CAPTURE CONTEXT POLICY: \(checks) checks passed")
    }
}
