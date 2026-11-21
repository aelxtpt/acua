import Foundation
import ApplicationServices

@MainActor final class CollectionBackend:EventStreamTreeCollectionBackend {
    typealias Element=Int
    struct Identity:Hashable {let value:Int;func hash(into h:inout Hasher) {h.combine(0)}}
    var graph:[Int:[Int]]=[:],roles:[Int:String]=[:],aliases:[Int:Int]=[:],subsets:[Int:EventStreamArraySubset]=[:]
    var events:[String]=[],contexts:[Int:EventStreamNodeContext]=[:]
    func identity(_ element:Int)->Identity {.init(value:aliases[element] ?? element)}
    func construct(_ element:Int,context:EventStreamNodeContext)->EventStreamTransformedNode<Int> {
        events.append("node:\(element)");contexts[element]=context
        var node=EventStreamTransformedNode(element:element);node.role=roles[element] ?? "AXGroup";node.title="node \(element)";return node
    }
    func children(_ element:Int,context:EventStreamNodeContext)->EventStreamChildArray<Int>? {
        events.append("children:\(element)")
        guard let children=graph[element] else {return nil}
        return .init(elements:children,subset:subsets[element])
    }
}
@main enum CollectionTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)};precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b=CollectionBackend(),collector=EventStreamTreeCollection(backend:b)
        b.graph=[0:[1,2],1:[3]];b.roles=[0:"AXWindow",1:"AXDateField",2:"AXButton",3:"AXIncrementor"]
        var filtered:[String]=[]
        var tree=collector.collect(0,context:.init(kind:1,isCatalyst:true,isWebShaped:true,isChromium:true,parentRole:"outer",windowFrame:.init(x:1,y:2,width:3,height:4)),filter:{index,element in filtered.append("\(index):\(element)");return true})
        check("preorder retains original child order",tree.preorder.map(\.node.element)==[0,1,3,2])
        check("completed forest retains one root and nested children",tree.roots.count==1 && tree.roots[0].children.map(\.node.element)==[1,2] && tree.roots[0].children[0].children[0].node.element==3)
        check("nodes are constructed before child selection",b.events==["node:0","children:0","node:1","children:1","node:3","children:3","node:2","children:2"])
        check("filter runs depth-first before each child descent",filtered==["0:1","0:3","1:2"])
        check("root never passes through child filter",!filtered.contains("0:0"))
        check("original paths retain nested array indices",tree.preorder.map(\.path)==[[],[0],[0,0],[1]])
        check("root receives supplied parent role",b.contexts[0]?.parentRole=="outer")
        check("descendants receive constructed parent role",b.contexts[1]?.parentRole=="AXWindow" && b.contexts[3]?.parentRole=="AXDateField")
        check("context flags and clipping frame survive collection",b.contexts[3]?.isCatalyst==true && b.contexts[3]?.isWebShaped==true && b.contexts[3]?.isChromium==true && b.contexts[3]?.windowFrame==CGRect(x:1,y:2,width:3,height:4))
        check("ordinary tree has no skipped references",tree.duplicateReferencesSkipped==0 && tree.depthLimitedReferencesSkipped==0)
        b.events=[];tree=collector.collect(0,filter:{_,element in element != 1})
        check("filter removes entire excluded subtree",tree.preorder.map(\.node.element)==[0,2] && !b.events.contains("node:3"))
        check("filter does not renumber remaining sibling path",tree.roots[0].children.first?.path==[1])
        tree=collector.collect(0,filter:{_,_ in false})
        check("all false child filter still includes root",tree.preorder.map(\.node.element)==[0])
        b.graph=[0:[1,2],1:[3],2:[3]];b.events=[]
        tree=collector.collect(0)
        check("shared references appear only in first depth-first branch",tree.preorder.map(\.node.element)==[0,1,3,2] && tree.roots[0].children[1].children.isEmpty)
        check("shared duplicate is counted and not constructed twice",tree.duplicateReferencesSkipped==1 && b.events.filter {$0=="node:3"}.count==1)
        b.graph=[0:[0]];tree=collector.collect(0)
        check("self-cycle terminates with root intact",tree.preorder.map(\.node.element)==[0] && tree.duplicateReferencesSkipped==1)
        b.graph=[0:[1],1:[0]];tree=collector.collect(0)
        check("two-node cycle terminates without discarding valid prefix",tree.preorder.map(\.node.element)==[0,1] && tree.duplicateReferencesSkipped==1)
        b.graph=[0:[1,2]];b.aliases=[2:1];tree=collector.collect(0)
        check("native-equal aliases share visited identity",tree.preorder.map(\.node.element)==[0,1] && tree.duplicateReferencesSkipped==1)
        b.aliases=[:];tree=collector.collect(0)
        check("hash collisions do not discard distinct identities",tree.preorder.map(\.node.element)==[0,1,2] && tree.duplicateReferencesSkipped==0)
        check("visited identity set is local to each add operation",collector.collect(0).preorder.count==3 && collector.collect(0).preorder.count==3)
        b.graph=[0:[1,1]];var seen=0
        tree=collector.collect(0,filter:{_,_ in seen += 1;return seen != 1})
        check("filtered reference remains eligible for later occurrence",tree.preorder.map(\.node.element)==[0,1] && tree.roots[0].children[0].path==[1] && tree.duplicateReferencesSkipped==0)
        b.graph=[0:[1,2]];b.subsets=[0:.init(count:1000,availableRanges:[900..<902])]
        tree=collector.collect(0,filter:{index,_ in index==1})
        check("partial child subset is preserved after filtering",tree.roots[0].childrenSubset == .init(count:1000,availableRanges:[900..<902]))
        check("path uses returned-array index rather than subset source offset",tree.roots[0].children[0].path==[1])
        b.graph=[0:[]];b.subsets=[0:.init(count:10,availableRanges:[0..<0])];tree=collector.collect(0)
        check("empty available child range retains original total count",tree.roots[0].children.isEmpty && tree.roots[0].childrenSubset?.count==10)
        b.graph=[:];tree=collector.collect(0)
        check("absent child response keeps leaf and nil subset",tree.roots[0].children.isEmpty && tree.roots[0].childrenSubset==nil)
        b.graph=Dictionary(uniqueKeysWithValues:(0..<202).map {($0,[$0+1])});b.subsets=[:];b.events=[]
        tree=collector.collect(0)
        check("depth 200 is included",tree.preorder.count==201 && tree.preorder.last?.path.count==200)
        check("depth201 is pruned before construction",tree.depthLimitedReferencesSkipped==1 && !b.events.contains("node:201"))
        b.events=[];tree=collector.collect(0,currentPath:Array(repeating:0,count:201))
        check("over-depth root makes no backend calls",tree.roots.isEmpty && tree.depthLimitedReferencesSkipped==1 && b.events.isEmpty)
        b.graph=[:];tree=collector.collect(0,currentPath:[4,8])
        check("supplied original index path is retained",tree.roots.first?.path==[4,8])
        let ax=AXUIElementCreateApplication(getpid()),child=AXUIElementCreateApplication(getpid()+10000)
        var reads:[String]=[]
        let lazy=EventStreamAXNode(ax,supportedAttributes:["AXRole"],attributes:["AXRole":"AXGroup" as NSString],transactionAttributes:["AXRole","AXKnownAbsent"],attributeReader:{name in reads.append(name);return name=="AXUnrequested" ? "fresh" as NSString:nil})
        check("unrequested lazy attribute can be read outside captured capability subset",lazy.attribute("AXUnrequested") as? String == "fresh" && reads==["AXUnrequested"])
        check("successful lazy read is retained in same node",lazy.attribute("AXUnrequested") as? String == "fresh" && reads.count==1)
        check("requested unsupported lazy attribute does not invoke reader",lazy.attribute("AXKnownAbsent")==nil && reads.count==1)
        let unsupported=EventStreamAXNode(ax,supportedAttributes:["AXRole"],transactionAttributes:["AXChildren"])
        check("requested unsupported child count skips native API",EventStreamNativeChildren(parent:unsupported).count("AXChildren")==nil)
        let invalid=EventStreamAXNode(ax,supportedAttributes:["AXChildren"],attributes:["AXChildren":NSNull()],transactionAttributes:["AXChildren"])
        check("cached nonarray child count is present zero",EventStreamNativeChildren(parent:invalid).count("AXChildren")==0)
        var position=CGPoint(x:10,y:20),size=CGSize(width:30,height:40)
        let geometry=EventStreamAXNode(ax,supportedAttributes:["AXRole"],transactionAttributes:["AXRole"],attributeReader:{name in
            if name=="AXPosition" {return AXValueCreate(.cgPoint,&position)}
            if name=="AXSize" {return AXValueCreate(.cgSize,&size)}
            return nil
        })
        check("child geometry can read unrequested position and size",EventStreamNativeChildren(parent:geometry).frame()==CGRect(x:10,y:20,width:30,height:40))
        let rid=EventStreamSnapshotAXIdentity(element:ax),cid=EventStreamSnapshotAXIdentity(element:child)
        let rootArray=[child] as NSArray,empty=[] as NSArray
        let raw:[EventStreamSnapshotAXIdentity:[String:AnyObject]]=[rid:["AXRole":"AXGroup" as NSString,"AXTitle":"root" as NSString,"AXChildren":rootArray],cid:["AXRole":"AXButton" as NSString,"AXTitle":"captured child" as NSString,"AXChildren":empty]]
        let rootPartial=EventStreamPartialValue(value:rootArray,array:.init(count:2,availableRanges:[0..<1]),string:nil)
        let leafPartial=EventStreamPartialValue(value:empty,array:.init(count:0,availableRanges:nil),string:nil)
        let requested=EventStreamSnapshotAttributes.common.union(["AXChildren"])
        let transaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:raw,requestedAttributes:requested),partialValues:[rid:["AXChildren":rootPartial],cid:["AXChildren":leafPartial]],roleFrequency:["AXGroup":1,"AXButton":1])
        let reader=EventStreamNativeSnapshots()
        EventStreamTreeTransactions.$current.withValue(transaction) {
            let native=EventStreamNativeTreeCollection.collect(reader.node(ax),context:.init(kind:1))
            check("controlled hierarchy feeds actual native node and child adapters",native.preorder.map(\.node.role)==["AXGroup","AXButton"] && native.preorder.last?.node.title=="captured child")
            check("native collection retains partial descriptor and original path",native.roots[0].childrenSubset == .init(count:2,availableRanges:[0..<1]) && native.preorder.last?.path==[0])
            check("native collection retains underlying AX identity",native.preorder.last.map {CFEqual($0.node.element.element,child)}==true)
            check("native collection infers child focus from original event role",native.preorder.last?.node.isFocusable==true)
        }
        let projections:[(AnyObject,String?)]=[(NSNumber(value:0),nil),(NSNumber(value:1),nil),(NSNumber(value:2),"2"),("1" as NSString,"1")]
        for (index,projection) in projections.enumerated() {
            let table:[EventStreamSnapshotAXIdentity:[String:AnyObject]]=[rid:["AXRole":"AXStaticText" as NSString,"AXValue":projection.0,"AXTraits":NSNumber(value:0),"AXChildren":empty]]
            let captured=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:table,requestedAttributes:requested),partialValues:[rid:["AXChildren":leafPartial]],roleFrequency:["AXStaticText":1])
            EventStreamTreeTransactions.$current.withValue(captured) {
                let tree=EventStreamNativeTreeCollection.collect(reader.node(ax),context:.init(kind:1))
                check("native collection retains captured boolean-versus-text projection \(index)",tree.preorder.count==1 && tree.preorder.first?.node.value==String(describing:projection.0) && tree.preorder.first?.node.stringValue==projection.1)
            }
        }
        enum Interrupted: Error { case cancelled }
        b.graph = [0: [1, 2], 1: [3]]; b.events = []
        var checkpoints = 0
        do {
            _ = try collector.collect(0, checkpoint: {
                checkpoints += 1
                if checkpoints == 3 { throw Interrupted.cancelled }
            })
            preconditionFailure("Cancelled capture returned a partial tree")
        } catch Interrupted.cancelled {
            check("cancelled collection propagates failure before returning a partial tree", true)
            check("cancellation stops native reads before entering the next child", b.events == ["node:0", "children:0"])
        } catch { preconditionFailure("Unexpected collection error: \(error)") }
        check("cancelled capture does not poison a later complete capture", collector.collect(0).preorder.count == 4)
        print("EVENT STREAM TREE COLLECTION: \(checks) checks passed")
    }
}
