import Foundation

struct EventStreamRenderSnapshotError:Error,CustomStringConvertible {
    var description:String {"Tree contains render without element ID, which is required for a snapshot."}
}

// Flat breadth-first VALUE copy; parent is the flat
// array index (not native identity, numeric ID, source path or sibling offset).
struct EventStreamRenderSnapshot:Codable,Hashable {
    struct Render:Codable,Hashable,Identifiable {
        var id:Int
        var text:String
        var detailText:String?
        var parentIndex:Int?
    }
    var subjectID:String
    var isFocus:Bool
    var renders:[Render]
    static func capture<Identity>(_ tree:EventStreamRenderedTree<Identity>,subjectID:String)throws->Self {
        var work=tree.roots.map {($0,Optional<Int>.none)},head=0,result:[Render]=[]
        while head<work.count {
            let (node,parent)=work[head]
            guard let id=node.elementID else {throw EventStreamRenderSnapshotError()}
            result.append(.init(id:id,text:node.text,detailText:node.detail,parentIndex:parent))
            work.append(contentsOf:node.children.map {($0,head)})
            head += 1
        }
        return .init(subjectID:subjectID,isFocus:tree.isFocusTree,renders:result)
    }
    // Append each node before indexing its parent;
    // the decoder does not validate graph shape. Invalid negative/future
    // indices trap. Root selection is a PREFIX of the counted root entries,
    // relying on the snapshot producer's breadth-first roots-first invariant.
    func renderTree()->EventStreamRenderedTree<Int> {
        var nodes:[EventStreamRenderedNode<Int>]=[],rootCount=0
        nodes.reserveCapacity(renders.count)
        for render in renders {
            let node=EventStreamRenderedNode(identity:render.id,elementID:render.id,text:render.text,detail:render.detailText)
            nodes.append(node)
            if let parent=render.parentIndex {nodes[parent].children.append(node)}
            else {rootCount += 1}
        }
        return .init(isFocusTree:isFocus,roots:Array(nodes.prefix(rootCount)))
    }
}
