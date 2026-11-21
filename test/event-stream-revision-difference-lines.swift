import Foundation

@main enum EventStreamRevisionDifferenceLineTests {
    typealias Node=EventStreamRenderedNode<Int>
    typealias Tree=EventStreamRenderedTree<Int>
    typealias Revision=EventStreamTreeRevision<Int,Int>
    typealias Notice=EventStreamDifferenceLineBudgetExceeded
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()throws->Bool) {
        guard (try? result())==true else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int,_ text:String?=nil,_ children:[Node]=[],native:Int?=nil)->Node {
        .init(identity:native ?? id,elementID:id,text:text ?? "node \(id)",sourcePath:[],children:children)
    }
    static func tree(_ roots:[Node],focus:Bool=false)->Tree {.init(isFocusTree:focus,roots:roots)}
    @MainActor static func revision(_ roots:[Node],lineage:String="lineage",focus:Bool=false,
                                    previous:Revision?=nil)throws->Revision {
        try .init(tree:.init(roots:[]),renderTree:tree(roots,focus:focus),lineageID:lineage,previousRevision:previous,identity:{$0})
    }
    @MainActor static func output(_ old:[Node],_ new:[Node],options:EventStreamRenderLineOptions=[],summary:Bool=false,
                                  ignore:Bool=false)->([String]?,[Notice]) {
        var notices:[Notice]=[]
        let lines=EventStreamRevisionDifferenceLines.build(old:tree(old),new:tree(new),options:options,
            summarizesRemovedElementIDs:summary,ignoreDifferenceLineBudget:ignore,onLineBudgetExceeded:{notices.append($0)})
        return (lines,notices)
    }
    // Independent budget oracle uses complete subtree sizes and the
    // fixed-vs-deferred counter boundary. It does not call production counters
    // or its build/formatting routine. Pair generation is validated separately.
    static func oracle(_ old:[Node],_ new:[Node],options:EventStreamRenderLineOptions,summary:Bool,ignore:Bool)->([String]?,[Notice]) {
        func all(_ roots:[Node])->[Node] {roots.flatMap {[$0]+all($0.children)}}
        func emit(_ root:Node,_ prefix:String,_ depth:Int,_ subtree:Bool)->[String] {
            var text=root.text
            if !options.contains(.withoutDetailText),let detail=root.detail {text += " "+detail}
            if !options.contains(.withoutElementID),let id=root.elementID {text="\(id) "+text}
            let line=prefix+String(repeating:"\t",count:depth)+text
            return [line]+(subtree ? root.children.flatMap {emit($0,prefix,depth+1,true)}:[])
        }
        let changes=Array(EventStreamRenderDifference(oldTree:tree(old),newTree:tree(new)))
        let budget=all(new).count
        var remaining=budget,hasRemoval=false,removed:[Int]=[],lines:[String]=[]
        for change in changes {
            if summary && change.kind == .remove {hasRemoval=true;continue}
            if !ignore {
                let subtree:Bool,cost:Int
                switch change {
                case .none:subtree=false;cost=0
                case .update:subtree=false;cost=1
                case let .insert(_,c):subtree = !options.contains(.withoutInsertionSubtree);cost=subtree ? all([c.node]).count:1
                case let .remove(_,c):subtree = !options.contains(.withoutRemovalSubtree);cost=subtree ? all([c.node]).count:1
                }
                if subtree && remaining>=0 && cost>remaining {return (nil,[.difference(budget)])}
                remaining -= cost
            }
        }
        if summary && hasRemoval && remaining<1 {return (nil,[.removedElementSummary(budget)])}
        let sorted=changes.sorted {a,b in a.path==b.path ? a.depthFirstRank<b.depthFirstRank:a.path.lexicographicallyPrecedes(b.path)}
        for change in sorted {
            switch change {
            case .none:break
            case let .update(_,n,_):lines += emit(n.node,"~",n.depth,false)
            case let .insert(_,n):lines += emit(n.node,"+",n.depth,!options.contains(.withoutInsertionSubtree))
            case let .remove(_,o):
                if summary {removed += all([o.node]).compactMap(\.elementID)}
                else {lines += emit(o.node,"-",o.depth,!options.contains(.withoutRemovalSubtree))}
            }
        }
        if !removed.isEmpty {
            // Independent range formatting by finding maximal runs in the
            // sorted unique set, rather than the production streaming scan.
            let ids=Set(removed).sorted();var ranges:[String]=[],i=0
            while i<ids.count {
                var end=i
                while end+1<ids.count && ids[end+1]-ids[end]==1 {end += 1}
                ranges.append(i==end ? "\(ids[i])":"\(ids[i])-\(ids[end])");i=end+1
            }
            lines.append("Removed element IDs: "+ranges.joined(separator:", "))
        }
        return (lines,[])
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        check("empty forests provide an available empty difference",output([],[]).0==[] && output([],[]).1.isEmpty)
        check("equal forests have no changed lines",output([node(0)],[node(0)]).0==[])
        check("one changed node fits a one-node budget",output([node(0,"old")],[node(0,"new")]).0==["~0 new"])
        let insertion=output([],[node(0,nil,[node(1)])])
        check("exact insertion subtree budget succeeds",insertion.0==["+0 node 0","+\t1 node 1"] && insertion.1.isEmpty)
        let removal=output([node(0)],[])
        check("zero new-node budget rejects a deferred removal",removal.0==nil && removal.1==[.difference(0)])
        let fixed=output([node(0)],[],options:[.withoutRemovalSubtree])
        check("fixed removal counter may exceed zero remaining budget",fixed.0==["-0 node 0"] && fixed.1.isEmpty)
        check("ignore ordinary budget permits full removal",output([node(0,nil,[node(1)])],[],ignore:true).0==["-0 node 0","-\t1 node 1"])
        let summarizedEmpty=output([node(0)],[],summary:true)
        check("empty new forest cannot reserve removal summary line",summarizedEmpty.0==nil && summarizedEmpty.1==[.removedElementSummary(0)])
        check("ignore flag still enforces empty-forest summary gate",output([node(0)],[],summary:true,ignore:true).1==[.removedElementSummary(0)])
        let reserve=output([node(0),node(1)],[node(0,"changed")],summary:true)
        check("exact update budget leaves no room for removal summary",reserve.0==nil && reserve.1==[.removedElementSummary(1)])
        check("ignore ordinary count leaves summary space",output([node(0),node(1)],[node(0,"changed")],summary:true,ignore:true).0==["~0 changed","Removed element IDs: 1"])
        let subtreeSummary=output([node(9,nil,[node(1),node(1),node(2),node(4)]),node(8)],[node(8)],options:[.withoutElementID,.withoutRemovalSubtree],summary:true)
        check("summary expands removed subtree despite removal flag and emits numeric IDs",subtreeSummary.0==["Removed element IDs: 1-2, 4, 9"])
        check("summary retains removed subtree IDs also present in new forest",output([node(9,nil,[node(0)])],[node(0)],summary:true,ignore:true).0==["+0 node 0","Removed element IDs: 0, 9"])
        check("summary deduplicates repeated numeric IDs",EventStreamRevisionDifferenceLines.removedIDRanges([3,1,2,1,3,7])=="1-3, 7")
        check("summary preserves signed ranges and comma-space separator",EventStreamRevisionDifferenceLines.removedIDRanges([-1,-3,-2,0,4,6,7])=="-3-0, 4, 6-7")
        check("empty summary range string is empty",EventStreamRevisionDifferenceLines.removedIDRanges([]).isEmpty)
        check("single repeated maximum does not overflow",EventStreamRevisionDifferenceLines.removedIDRanges([Int.max,Int.max])=="\(Int.max)")
        check("signed endpoint ranges preserve full Int bounds",EventStreamRevisionDifferenceLines.removedIDRanges([Int.min,Int.min+1,Int.max-1,Int.max])=="\(Int.min)-\(Int.min+1), \(Int.max-1)-\(Int.max)")
        let leaf=node(0,"text");leaf.detail=""
        check("present empty detail keeps the trailing space",output([],[leaf]).0==["+0 text "])
        check("line options suppress ID and detail after prefix",output([],[leaf],options:[.withoutElementID,.withoutDetailText]).0==["+text"])
        let oldDetail=node(0),newDetail=node(0);oldDetail.detail="old";newDetail.detail="new"
        check("detail-only changes do not produce text updates",output([oldDetail],[newDetail]).0==[])
        let replaced=output([node(0)],[node(1)],ignore:true)
        check("equal-path replacement emits removal before insertion",replaced.0==["-0 node 0","+1 node 1"])
        let negativeOld=[node(0),node(10),node(11),node(12)],negativeNew=[node(0,nil,[node(1)])]
        let negative=output(negativeOld,negativeNew,options:[.withoutRemovalSubtree])
        check("negative remaining fixed budget keeps subtree acceptance",negative.0==["+\t1 node 1","-10 node 10","-11 node 11","-12 node 12"])
        let oldNative=node(7,"same",native:100),newNative=node(7,"same",native:200)
        let oldRevision=try revision([oldNative],lineage:"old"),newRevision=try revision([newNative],lineage:"unrelated")
        var notices:[Notice]=[]
        let identityLines=newRevision.differenceLines(from:oldRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})
        check("revision differences pair numeric snapshots rather than native identity",identityLines==[] && notices.isEmpty)
        newNative.text="changed"
        check("unrelated lineage still compares snapshots",newRevision.differenceLines(from:oldRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{_ in})==["~7 changed"])
        check("revision comparison does not require stored changes",newRevision.changes.isEmpty)
        oldNative.sourcePath=nil;newNative.sourcePath=nil
        check("snapshot comparison ignores absent source paths",newRevision.differenceLines(from:oldRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{_ in})==["~7 changed"])
        oldNative.elementID=nil
        let failedOld=newRevision.differenceLines(from:oldRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})
        check("old snapshot error returns unavailable without callback",failedOld==nil && notices.isEmpty)
        oldNative.elementID=7;newNative.elementID=nil
        check("current snapshot error returns unavailable without callback",newRevision.differenceLines(from:oldRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})==nil && notices.isEmpty)
        check("same revision still validates snapshot rather than shortcut",newRevision.differenceLines(from:newRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})==nil)
        newNative.elementID=7
        check("same valid revision provides empty available difference",newRevision.differenceLines(from:newRevision,options:[],summarizesRemovedElementIDs:true,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{_ in})==[])
        let ancestorNode=node(0,"first"),ancestor=try revision([ancestorNode]),middleNode=node(0,"middle"),middle=try revision([middleNode],previous:ancestor),currentNode=node(0,"last"),current=try revision([currentNode],previous:middle)
        check("arbitrary ancestor comparison uses requested snapshot",current.differenceLines(from:ancestor,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{_ in})==["~0 last"])
        middleNode.elementID=nil
        check("unrequested broken intermediate revision does not block comparison",current.differenceLines(from:ancestor,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{_ in})==["~0 last"])
        let partial=current.renderTreeInspectorPayload()!
        check("inspector keeps current and first after previous failure",partial.current.renders[0].text=="last" && partial.previous==nil && partial.first?.renders[0].text=="first")
        middleNode.elementID=0;ancestorNode.elementID=nil
        let noFirst=current.renderTreeInspectorPayload()!
        check("inspector root failure does not suppress valid previous",noFirst.first==nil && noFirst.previous?.renders[0].text=="middle")
        currentNode.elementID=nil
        check("inspector current failure suppresses entire payload",current.renderTreeInspectorPayload()==nil)
        currentNode.elementID=0;ancestorNode.elementID=0
        let rootPayload=ancestor.renderTreeInspectorPayload()!
        check("root inspector suppresses equal first and absent previous",rootPayload.previous==nil && rootPayload.first==nil && rootPayload.current.subjectID==ancestor.lineageID)
        currentNode.text="first"
        let returned=current.renderTreeInspectorPayload()!
        check("first suppression compares values across distinct revisions",returned.first==nil && current !== ancestor && returned.previous != nil)
        let detailRoot=node(0),detailRootRevision=try revision([detailRoot]);let detailChild=node(0);detailChild.detail="extra"
        let detailChildRevision=try revision([detailChild],previous:detailRootRevision)
        check("inspector first equality includes detail metadata",detailChildRevision.renderTreeInspectorPayload()?.first != nil)
        let focusRevision=try revision([node(0)],focus:true,previous:detailRootRevision)
        check("inspector first equality includes focus flag",focusRevision.renderTreeInspectorPayload()?.first != nil)
        check("difference output ignores focus flag alone",focusRevision.differenceLines(from:detailRootRevision,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{_ in})==[])
        let brokenFocus=node(3),mainOnly=try Revision(tree:.init(roots:[]),renderTree:tree([node(12)]),focusTree:.init(roots:[]),focusRenderTree:tree([brokenFocus]),identity:{$0})
        brokenFocus.elementID=nil;var focusFailed=false
        do {_=try mainOnly.focusRenderTreeSnapshot()} catch is EventStreamRenderSnapshotError {focusFailed=true}
        check("inspector ignores a separately broken focus snapshot",focusFailed && mainOnly.renderTreeInspectorPayload() != nil)
        check("main difference ignores a separately broken focus snapshot",mainOnly.differenceLines(from:mainOnly,options:[],summarizesRemovedElementIDs:false,ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{notices.append($0)})==[] && notices.isEmpty)
        let payload=current.renderTreeInspectorPayload()!,encoded=try JSONEncoder().encode(payload),json=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        check("inspector coding uses current previous first optional schema",Set(json.keys)==["current","previous"])
        check("inspector Codable and hash preserve complete value",try JSONDecoder().decode(EventStreamRenderInspectorPayload.self,from:encoded)==payload && Set([payload,payload]).count==1)
        let held=payload;currentNode.text="after payload"
        check("inspector payload is independent of subsequent live mutation",held.current.renders[0].text=="first")
        var big=node(10)
        for i in 11...3010 {big=node(i,nil,[big])}
        let large=output([big],[node(0)])
        check("large removed subtree reports new-forest budget once",large.0==nil && large.1==[.difference(1)])
        // All16 option masks, summary/ignore combinations and100 flat forest
        // pairs include duplicate IDs and text changes.
        var scenarios=0
        let words:[[Int]]=[[],[0],[1],[0,1],[1,0],[0,0],[1,1],[0,1,0],[2,0,1],[2,1,0]]
        for mask in UInt8(0)..<16 {for summary in [false,true] {for ignore in [false,true] {for o in words {for n in words {
            let old=o.map {node($0)},new=n.enumerated().map {node($0.element,$0.offset%2==0 ? "changed \($0.element)":nil)}
            let options=EventStreamRenderLineOptions(rawValue:mask)
            let got=output(old,new,options:options,summary:summary,ignore:ignore),want=oracle(old,new,options:options,summary:summary,ignore:ignore)
            guard got.0==want.0 && got.1==want.1 else {fatalError("FAIL: budget oracle mask\(mask) summary\(summary) ignore\(ignore) \(o)->\(n): \(String(describing:got)) != \(String(describing:want))")}
            scenarios += 1
        }}}}}
        check("all line flags and policy oracle agree across6400 scenarios",scenarios==6400)
        print("EVENT STREAM REVISION DIFFERENCE LINES: \(checks) checks passed; \(scenarios) policy scenarios")
    }
}
