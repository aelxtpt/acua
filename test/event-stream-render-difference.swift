import Foundation

@main enum EventStreamRenderDifferenceTests {
    typealias Node=EventStreamRenderedNode<Int>
    typealias Tree=EventStreamRenderedTree<Int>
    typealias Diff=EventStreamRenderDifference<Int>
    typealias Change=EventStreamRenderChange<Int>
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int,_ text:String?=nil,_ children:[Node]=[])->Node {
        .init(identity:id,text:text ?? "node \(id)",sourcePath:[700+id],children:children)
    }
    static func tree(_ roots:[Node],focus:Bool=false)->Tree {.init(isFocusTree:focus,roots:roots)}
    static func difference(_ old:[Node],_ new:[Node])->Diff {.init(oldTree:tree(old),newTree:tree(new))}
    static func stamp(_ c:Change)->String {"\(c.kind.rawValue):\(c.offset):\(c.new?.node.identity ?? -1):\(c.old?.node.identity ?? -1)"}
    // Independent small-domain oracle: enumerate ALL subsequences and select
    // the first maximum-length increasing sequence of old positions. No tails
    // array/binary search or production matching helpers are reused here.
    static func expected(_ old:[Int],_ new:[Int])->[String] {
        var prefix=0,result:[String]=[]
        while prefix<min(old.count,new.count),old[prefix]==new[prefix] {
            result.append("0:\(prefix):\(new[prefix]):\(old[prefix])");prefix += 1
        }
        var remaining:[Int:Int]=[:]
        for i in prefix..<old.count {remaining[old[i]]=i}
        let matches=new.dropFirst(prefix).compactMap {id in remaining[id].map {(id,$0)}}
        var best:[Int]=[]
        for mask in 0..<(1<<matches.count) {
            let indices=matches.indices.filter {mask & (1<<$0) != 0}
            let offsets=indices.map {matches[$0].1}
            guard zip(offsets,offsets.dropFirst()).allSatisfy({$0<$1}) else {continue}
            if indices.count>best.count || (indices.count==best.count && indices.lexicographicallyPrecedes(best)) {best=indices}
        }
        let selected=Set(best.map {matches[$0].0})
        for i in prefix..<new.count {
            let id=new[i]
            if remaining.removeValue(forKey:id) != nil && selected.contains(id) {result.append("0:\(i):\(id):\(id)")}
            else {result.append("1:\(i):\(id):-1")}
        }
        result += remaining.map {"3:\($0.value):-1:\($0.key)"}.sorted()
        return result
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        if let probe=CommandLine.arguments.first(where:{$0.hasPrefix("--overflow-counter-")}) {
            var counter=EventStreamRenderTraversalCounter<Int>(integerLiteral:Int.max)
            if probe=="--overflow-counter-add" {counter.add(counter:1)}
            else {counter.add(counter:.init(items:[node(1)]));_=counter.total()}
            return // Returning normally must fail the parent's trapping probe.
        }
        check("empty forests have no changes",Array(difference([],[])).isEmpty)
        let old=node(1,"old",[node(2)]),new=node(1,"new",[node(2)])
        let buffer=difference([old],[new]).buffer()
        check("same native identity pairs changed text",buffer.changes.map(\.kind)==[.update,.none])
        check("paired payload keeps old and new references",buffer.changes[0].old?.node===old && buffer.changes[0].new?.node===new)
        check("update description uses old then new text",buffer.changes[0].description=="Update at 0 from 'old' to 'new'.")
        check("unchanged description retains both paired texts",buffer.changes[1].description=="No change at 0 from 'node 2' to 'node 2'.")
        check("render cursor paths ignore source diagnostic paths",buffer.changes.map(\.path)==[[0],[0,0]])
        check("child offsets are sibling positions",buffer.changes.map(\.offset)==[0,0])
        check("root and child cursor depths start at zero",buffer.changes.map {$0.new!.depth}==[0,1])
        let detailOld=node(8),detailNew=node(8);detailOld.detail="old detail";detailNew.detail="new detail";detailOld.elementID=44;detailNew.elementID=99
        check("detail and numeric ID changes do not create text updates",Array(difference([detailOld],[detailNew])).map(\.kind)==[.none])
        check("focus flags do not affect render differences",Array(Diff(oldTree:tree([detailOld]),newTree:tree([detailNew],focus:true))).map(\.kind)==[.none])
        let moved=Array(difference([node(1),node(2)],[node(2),node(1)]))
        check("reorder tie preserves earliest new subsequence",moved.map(stamp)==["0:0:2:2","1:1:1:-1"])
        check("rejected moved pair does not invent a removal",!moved.contains {$0.kind == .remove})
        let duplicate=Array(difference([node(1,"first"),node(1,"last")],[node(2),node(1,"next"),node(1,"last")]))
        check("old remainder dictionary keeps last duplicate",duplicate[1].old?.node.text=="last" && duplicate[1].kind == .update)
        check("new duplicate consumes mapping only once",duplicate.map(\.kind)==[.insert,.update,.insert])
        check("common prefix retains duplicates as distinct pairs",Array(difference([node(1),node(1)],[node(1),node(1)])).map(\.kind)==[.none,.none])
        let batch=Array(difference([node(1,nil,[node(3,nil,[node(5)])]),node(2,nil,[node(4)])],[node(1,nil,[node(3,nil,[node(5)])]),node(2,nil,[node(4)])]))
        check("structural queue emits breadth-first sibling batches",batch.map {$0.new!.node.identity}==[1,2,3,4,5])
        var sorted=difference([node(1,nil,[node(3,nil,[node(5)])]),node(2,nil,[node(4)])],[node(1,nil,[node(3,nil,[node(5)])]),node(2,nil,[node(4)])]).buffer()
        sorted.sortChangesDepthFirst()
        check("buffer sort produces render depth-first order",sorted.changes.map {$0.new!.node.identity}==[1,3,5,2,4] && sorted.sortedDepthFirst)
        let sortedStamps=sorted.changes.map {$0.path};sorted.sortChangesDepthFirst()
        check("sorting a sorted buffer is idempotent",sorted.changes.map(\.path)==sortedStamps)
        var replace=difference([node(1)],[node(2)]).buffer();replace.sortChangesDepthFirst()
        check("equal path removes before insertion",replace.changes.map(\.kind)==[.remove,.insert])
        check("depth-first tie ranks differ from enum tags",[Change.none(offset:0,new:.init(node:new,path:[0]),old:.init(node:old,path:[0])),.remove(offset:0,old:.init(node:old,path:[0])),.insert(offset:0,new:.init(node:new,path:[0])),.update(offset:0,new:.init(node:new,path:[0]),old:.init(node:old,path:[0]))].map(\.depthFirstRank)==[0,1,2,3])
        var unsortedCopy=difference([node(1,nil,[node(3)]),node(2)],[node(1,nil,[node(3)]),node(2)]).buffer();let untouched=unsortedCopy;unsortedCopy.sortChangesDepthFirst()
        check("buffer value copies sort independently",!untouched.sortedDepthFirst && untouched.changes.map {$0.new!.node.identity}==[1,2,3])
        check("buffer retains its original difference",untouched.difference.oldTree.roots.count==2 && untouched.difference.newTree.roots.count==2)
        let subtree=node(1,nil,[node(2,nil,[node(3)]),node(4)])
        let inserted=Array(difference([],[subtree]))
        check("inserted subtree emits one structural change",inserted.count==1 && inserted[0].kind == .insert)
        check("insertion description uses the expected punctuation",inserted[0].description=="Insertion at 0 with 'node 1'.")
        check("removed subtree emits one structural change",Array(difference([subtree],[])).count==1)
        check("insert lines include subtree by default",inserted[0].lines()==["+node 1","+\tnode 2","+\t\tnode 3","+\tnode 4"])
        check("insertion option omits descendants",inserted[0].lines(options:[.withoutInsertionSubtree])==["+node 1"])
        let removed=Array(difference([subtree],[]))[0]
        check("removal description uses the expected punctuation",removed.description=="Removal at 0 with 'node 1'.")
        check("removal prefix precedes indentation",removed.lines()==["-node 1","-\tnode 2","-\t\tnode 3","-\tnode 4"])
        check("removal option omits descendants",removed.lines(options:[.withoutRemovalSubtree])==["-node 1"])
        check("unchanged pairs serialize no lines",batch.flatMap {$0.lines()}.isEmpty)
        check("update only serializes new node",buffer.changes[0].lines()==["~new"])
        let nested=Change.insert(offset:0,new:.init(node:subtree,path:[0,2,0]));subtree.elementID=41;subtree.detail="details"
        check("nested insertion adds outer depth to subtree depth",nested.lines(indent:"·")[0]=="+··41 node 1 details" && nested.lines(indent:"·")[2]=="+····node 3")
        check("line flags propagate to difference serialization",nested.lines(options:[.withoutElementID,.withoutDetailText,.withoutInsertionSubtree])==["+\t\tnode 1"])
        old.elementID=7;new.elementID=88;buffer.changes[0].inheritElementID()
        check("actual paired update inherits numeric ID",new.elementID==7)
        let noneOld=node(2),noneNew=node(2);noneOld.elementID=8
        Array(difference([noneOld],[noneNew]))[0].inheritElementID()
        check("actual unchanged pair inherits numeric ID",noneNew.elementID==8)
        let fresh=node(9);Array(difference([],[fresh]))[0].inheritElementID()
        check("insertion does not inherit unrelated ID",fresh.elementID==nil)
        let movedOld=[node(1),node(2)],movedNew=[node(2),node(1)];EventStreamRenderIDs.setInitialIDs(tree(movedOld))
        for change in difference(movedOld,movedNew) {change.inheritElementID()}
        let movedIDs=try EventStreamRenderIDs.assign(main:tree(movedNew))
        check("reorder inheritance integrates with allocator",movedIDs.values==[2:1,1:2])
        var sourceTree=tree([node(11)]);let sequence=Diff(oldTree:sourceTree,newTree:tree([node(11)]));sourceTree.roots.append(node(12))
        check("sequence retains root-array value",Array(sequence).count==1)
        let mutableOld=node(1),mutableNew=node(1);let deferred=difference([mutableOld],[mutableNew]);mutableNew.text="late"
        check("changes observe node mutation before iteration",Array(deferred)[0].kind == .update)
        let childOld=node(3),childNew=node(3),parentOld=node(1,nil,[childOld]),parentNew=node(1,nil,[childNew])
        var iterator=difference([parentOld,node(2)],[parentNew,node(2)]).makeIterator()
        _=iterator.next();parentNew.children.append(node(99));childNew.text="after root"
        check("buffered root sibling precedes queued child pair",iterator.next()?.new?.node.identity==2)
        let childChange=iterator.next()
        check("queued child sees later text mutation",childChange?.kind == .update && childChange?.new?.node===childNew)
        check("queued child array excludes later appended child",iterator.next()==nil && iterator.next()==nil)
        var firstIterator=deferred.makeIterator();let fork=firstIterator;_=firstIterator.next()
        var forked=fork;check("iterator value copies consume independently",forked.next() != nil && firstIterator.next()==nil)
        mutableNew.text="after buffering";let buffered=difference([mutableOld],[mutableNew]).buffer();mutableNew.text="visible later"
        check("buffered lines retain live node reference",buffered.changes[0].lines()==["~visible later"])
        check("buffered description reads live text without changing kind",buffered.changes[0].description=="Update at 0 from 'node 1' to 'visible later'.")
        mutableOld.elementID=77;buffered.changes[0].inheritElementID()
        check("inheritance reads old numeric ID at call time",mutableNew.elementID==77)
        var fixed:EventStreamRenderTraversalCounter<Int>=5
        check("fixed counter is empty with nonzero accumulated count",fixed.isEmpty && fixed.total()==5)
        var signed:EventStreamRenderTraversalCounter<Int> = -2
        check("fixed negative count is not clamped",signed.total() == -2)
        var counter=inserted[0].lineCounter();var visits:[Int]=[]
        check("subtree counter starts deferred",counter.count==0 && !counter.isEmpty)
        let partial=counter.increment(while:{visits.append($0);return $0<2})
        check("counter predicate sees initial and updated totals",partial==2 && visits==[0,1,2] && !counter.isEmpty)
        check("counter total resumes partial consumption",counter.total()==4 && counter.isEmpty && counter.total()==4)
        var noWork=removed.lineCounter();var calls=0
        let declined=noWork.increment(while:{_ in calls += 1;return false})
        check("false initial predicate does not consume",declined==0 && calls==1 && !noWork.isEmpty)
        var single=inserted[0].lineCounter(options:[.withoutInsertionSubtree])
        check("single insertion counter is fixed at one",single.isEmpty && single.total()==1)
        var zero=batch[0].lineCounter(),one=buffer.changes[0].lineCounter()
        check("unchanged and update counters are fixed",zero.isEmpty && zero.total()==0 && one.isEmpty && one.total()==1)
        let dynamic=node(10);var lazy=EventStreamRenderTraversalCounter(items:[dynamic]);dynamic.children.append(node(11))
        check("counter discovers reference children at consumption",lazy.total()==2)
        let reverseFirst=node(21),reverseLast=node(22);var reverse=EventStreamRenderTraversalCounter(items:[reverseFirst,reverseLast])
        _=reverse.increment(while:{$0<1});reverseLast.children.append(node(23));reverseFirst.children.append(node(24))
        check("counter consumes last root first and captures children immediately",reverse.total()==3)
        var donor=EventStreamRenderTraversalCounter(items:[node(31,nil,[node(32)])]);_=donor.increment(while:{$0<1})
        var aggregate:EventStreamRenderTraversalCounter<Int>=2;aggregate.add(counter:donor)
        check("adding counter copies pending work and accumulated count",aggregate.count==3 && aggregate.total()==4 && donor.total()==2)
        var rootsOld=node(0),rootsNew=node(0)
        for id in 1...600 {rootsOld=node(id,nil,[rootsOld]);rootsNew=node(id,nil,[rootsNew])}
        let deep=Array(difference([rootsOld],[rootsNew]))
        check("deep difference traversal is iterative without depth clamp",deep.count==601 && deep.last?.path.count==601)
        // All old/new words of length <=4 over three identities: duplicates,
        // gaps, unmatched prefixes and every short reorder/tie are included.
        var words:[[Int]]=[[]],level:[[Int]]=[[]]
        for _ in 1...4 {level=level.flatMap {prefix in (0..<3).map {prefix+[$0]}};words += level}
        var scenarios=0
        for o in words {for n in words {
            let actual=Array(difference(o.map {node($0)},n.map {node($0)}))
            let canonical=actual.filter {$0.kind != .remove}.map(stamp)+actual.filter {$0.kind == .remove}.map(stamp).sorted()
            guard canonical==expected(o,n) else {fatalError("FAIL: exhaustive \(o) -> \(n): \(canonical) != \(expected(o,n))")}
            scenarios += 1
        }}
        check("exhaustive duplicate and reorder oracle agrees on 14641 scenarios",scenarios==14641)
        for suffix in ["add","increment"] {
            let process=Process();process.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--overflow-counter-\(suffix)"]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run();process.waitUntilExit()
            check("counter \(suffix) overflow traps",process.terminationReason == .uncaughtSignal && process.terminationStatus != 0)
        }
        print("EVENT STREAM RENDER DIFFERENCE: \(checks) checks passed; \(scenarios) exhaustive scenarios")
    }
}
