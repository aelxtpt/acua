import Foundation

// UIElementTreeTable<ID,Int> doubles as the value/path container. This
// alias shares its representation, not the collected-tree preorder-ID
// algorithm; published IDs below come from render/revision ownership.
typealias EventStreamRenderIDTable<Identity:Hashable> = EventStreamCollectedTreeTable<Identity>

struct EventStreamMissingRenderSourcePath:Error,CustomStringConvertible {
    var description:String {"Revision render trees must have source paths referencing the element tree."}
}

// Lazy maximum of CURRENT IDs in the
// captured main forest on first next(), then checked consecutive increments.
// No existing IDs means a base of zero, so the first new ID is1.
struct EventStreamNextRenderID<Identity:Hashable> {
    private let tree:EventStreamRenderedTree<Identity>
    private var previous:Int?
    init(_ tree:EventStreamRenderedTree<Identity>) {self.tree=tree}
    mutating func next()->Int {
        let base=previous ?? tree.preorder.compactMap(\.elementID).max() ?? 0
        let result=base+1
        previous=result
        return result
    }
}

@MainActor enum EventStreamRenderIDs {
    // The root revision numbers every render node, including duplicate
    // native identities, in depth-first order from zero.
    static func setInitialIDs<Identity>(_ tree:EventStreamRenderedTree<Identity>) {
        for (id,node) in tree.preorder.enumerated() {node.elementID=id}
    }
    // Paired change payload. The difference iterator must decide
    // which nodes form a pair; this primitive does not infer a diff.
    static func inherit<Identity>(from old:EventStreamRenderedNode<Identity>,to new:EventStreamRenderedNode<Identity>) {
        if let id=old.elementID {new.elementID=id}
    }
    // Main then optional focus
    // preorder. Missing path throws before touching that node's ID. Existing
    // IDs win, then the earlier identity mapping, then the lazy main allocator.
    // Dictionary writes deliberately retain prior paths on duplicate identity.
    static func assign<Identity>(main:EventStreamRenderedTree<Identity>,
                                 focus:EventStreamRenderedTree<Identity>?=nil)throws->EventStreamRenderIDTable<Identity> {
        var next=EventStreamNextRenderID(main),values:[Identity:Int]=[:],paths:[Int:[Int]]=[:]
        for node in main.preorder+(focus?.preorder ?? []) {
            guard let path=node.sourcePath else {throw EventStreamMissingRenderSourcePath()}
            let id=node.elementID ?? values[node.identity] ?? next.next()
            node.elementID=id
            values[node.identity]=id
            paths[id]=path
        }
        return .init(values:values,paths:paths)
    }
    // Require both numeric path and inverse identity. If that
    // identity is in the optional focus tree, use its stored path there;
    // otherwise use the main tree. The path is trusted, not identity-rechecked.
    static func item<Element,Identity>(for id:Int,in ids:EventStreamRenderIDTable<Identity>,
                                      tree:EventStreamCollectedTree<Element>,focus:EventStreamCollectedTree<Element>?=nil,
                                      identity:(Element)->Identity)->EventStreamCollectedItem<Element>? {
        guard let path=ids.paths[id],let native=ids.elements[id] else {return nil}
        if var focused=focus,focused.table(identity:{identity($0.element)}).values[native] != nil {
            return item(at:path,in:focused)
        }
        return item(at:path,in:tree)
    }
    private static func item<Element>(at path:[Int],in tree:EventStreamCollectedTree<Element>)->EventStreamCollectedItem<Element>? {
        guard let first=path.first,tree.roots.indices.contains(first) else {return nil}
        var result=tree.roots[first]
        for index in path.dropFirst() {
            guard result.children.indices.contains(index) else {return nil}
            result=result.children[index]
        }
        return result
    }
}
