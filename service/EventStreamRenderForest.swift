import Foundation

// UIElementRender is a reference object. Native identity and its optional
// published numeric ID are separate; revision ownership assigns the latter.
final class EventStreamRenderedNode<Identity:Hashable> {
    let identity:Identity
    var elementID:Int?
    var text:String
    var detail:String?
    var sourcePath:[Int]?
    var children:[EventStreamRenderedNode]
    init(identity:Identity,elementID:Int?=nil,text:String,detail:String?=nil,
         sourcePath:[Int]?=nil,children:[EventStreamRenderedNode]=[]) {
        self.identity=identity;self.elementID=elementID;self.text=text;self.detail=detail
        self.sourcePath=sourcePath;self.children=children
    }
    func line(indent:Character="\t",depth:Int=0,options:EventStreamRenderLineOptions=[])->String {
        EventStreamRenderNode(id:elementID,description:text,detail:detail).line(indent:indent,depth:depth,options:options)
    }
}

struct EventStreamRenderedTree<Identity:Hashable> {
    var isFocusTree:Bool
    var roots:[EventStreamRenderedNode<Identity>]
    var preorder:[EventStreamRenderedNode<Identity>] {
        var work=Array(roots.reversed()),result:[EventStreamRenderedNode<Identity>]=[]
        while let node=work.popLast() {result.append(node);work.append(contentsOf:node.children.reversed())}
        return result
    }
    func lines(indent:Character="\t",options:EventStreamRenderLineOptions=[])->[String] {
        var work=roots.reversed().map {($0,0)},result:[String]=[]
        while let (node,depth)=work.popLast() {
            result.append(node.line(indent:indent,depth:depth,options:options))
            work.append(contentsOf:node.children.reversed().map {($0,depth+1)})
        }
        return result
    }
}

@MainActor enum EventStreamRenderForest {
    // Every source item is described in preorder. Empty descriptions omit
    // the node and promote its descendants to the nearest rendered ancestor.
    // Source paths keep their positions in the source tree.
    static func build<Element,Identity:Hashable,Context>(
        _ tree:EventStreamCollectedTree<Element>,context:inout Context,identity:(Element)->Identity,
        describe:(EventStreamTransformedNode<Element>,inout Context)throws->String
    ) rethrows -> EventStreamRenderedTree<Identity> {
        typealias Node=EventStreamRenderedNode<Identity>
        var roots:[Node]=[]
        var work=tree.roots.enumerated().reversed().map {(item:$0.element,path:[$0.offset],parent:Optional<Node>.none)}
        while let (item,path,parent)=work.popLast() {
            let text=try describe(item.node,&context)
            let nearest:Node?
            if text.isEmpty {nearest=parent}
            else {
                let rendered=Node(identity:identity(item.node.element),text:text,
                    detail:subsetDescription(item.childrenSubset),sourcePath:path)
                if let parent {parent.children.append(rendered)} else {roots.append(rendered)}
                nearest=rendered
            }
            work.append(contentsOf:item.children.enumerated().reversed().map {($0.element,path+[$0.offset],nearest)})
        }
        // Check the SOURCE root count and identities after mapping,
        // even if that root's empty description caused its output omission.
        let focus:Bool
        if tree.roots.count==1 {
            let root=identity(tree.roots[0].node.element)
            focus=tree.focusedElement.map {root==identity($0.element)} ?? false
        } else {focus=false}
        return .init(isFocusTree:focus,roots:roots)
    }
    // Print the stored half-open range bounds without adjustment,
    // sorting, validation or omission of empty ranges. nil ranges omit detail;
    // a present empty array still produces `(showing  of N items)`.
    static func subsetDescription(_ subset:EventStreamArraySubset?)->String? {
        guard let subset,let ranges=subset.availableRanges else {return nil}
        return "(showing \(ranges.map {"\($0.lowerBound)-\($0.upperBound)"}.joined(separator:", ")) of \(subset.count) items)"
    }
}
