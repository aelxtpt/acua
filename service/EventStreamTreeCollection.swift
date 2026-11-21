import Foundation

// The collected tree precedes transformations, IDs and revision comparison.
// It preserves the constructor's element and its child-subset descriptor.
struct EventStreamCollectedItem<Element> {
    let node:EventStreamTransformedNode<Element>
    let path:[Int]
    var subtree:EventStreamCollectedTree<Element>
    let childrenSubset:EventStreamArraySubset?
    var children:[Self] {subtree.roots}
    init(node:EventStreamTransformedNode<Element>,path:[Int],children:[Self],childrenSubset:EventStreamArraySubset?) {
        self.init(node:node,path:path,subtree:.init(roots:children),childrenSubset:childrenSubset)
    }
    init(node:EventStreamTransformedNode<Element>,path:[Int],subtree:EventStreamCollectedTree<Element>,childrenSubset:EventStreamArraySubset?) {
        self.node=node;self.path=path;self.subtree=subtree;self.childrenSubset=childrenSubset
    }
    func replacing(node:EventStreamTransformedNode<Element>)->Self {
        .init(node:node,path:path,subtree:subtree,childrenSubset:childrenSubset)
    }
    func replacing(subtree:EventStreamCollectedTree<Element>)->Self {
        .init(node:node,path:path,subtree:subtree,childrenSubset:childrenSubset)
    }
    func replacing(children:[Self])->Self {replacing(node:node,children:children)}
    func replacing(node:EventStreamTransformedNode<Element>,children:[Self])->Self {
        var next=subtree;next.roots=children
        return .init(node:node,path:path,subtree:next,childrenSubset:childrenSubset)
    }
}

struct EventStreamCollectedTree<Element> {
    // Item stores a complete child tree, not just its items. Mutating
    // items invalidates property/table caches while preserving focusedElement.
    var roots:[EventStreamCollectedItem<Element>] {didSet {invalidateCaches()}}
    let duplicateReferencesSkipped:Int
    let depthLimitedReferencesSkipped:Int
    var focusedElement:EventStreamTransformedNode<Element>?
    private(set) var descendantProperties:[KeyPath<EventStreamTransformedNode<Element>,Bool>:Bool]=[:]
    private(set) var leafProperties:[KeyPath<EventStreamTransformedNode<Element>,Bool>:Bool]=[:]
    private var cachedTable:Any?
    var hasCachedTable:Bool {cachedTable != nil}
    init(roots:[EventStreamCollectedItem<Element>],duplicateReferencesSkipped:Int=0,
         depthLimitedReferencesSkipped:Int=0,focusedElement:EventStreamTransformedNode<Element>?=nil) {
        self.roots=roots;self.duplicateReferencesSkipped=duplicateReferencesSkipped
        self.depthLimitedReferencesSkipped=depthLimitedReferencesSkipped;self.focusedElement=focusedElement
    }
    private mutating func invalidateCaches() {
        descendantProperties.removeAll(keepingCapacity:true)
        leafProperties.removeAll(keepingCapacity:true);cachedTable=nil
    }
    // Cache by node KeyPath, including false. Recursive
    // cache updates write through the parent items array, invalidating its old
    // caches before the result of this query is stored.
    mutating func hasDescendant(where property:KeyPath<EventStreamTransformedNode<Element>,Bool>)->Bool {
        if let result=descendantProperties[property] {return result}
        for index in roots.indices {
            if roots[index].node[keyPath:property] {descendantProperties[property]=true;return true}
            if roots[index].subtree.hasDescendant(where:property) {descendantProperties[property]=true;return true}
        }
        descendantProperties[property]=false;return false
    }
    mutating func hasLeafDescendant(where property:KeyPath<EventStreamTransformedNode<Element>,Bool>)->Bool {
        if let result=leafProperties[property] {return result}
        for index in roots.indices {
            if roots[index].children.isEmpty,roots[index].node[keyPath:property] {leafProperties[property]=true;return true}
            if roots[index].subtree.hasLeafDescendant(where:property) {leafProperties[property]=true;return true}
        }
        leafProperties[property]=false;return false
    }
    // Identity is the element's Identifiable getter,
    // supplied by the owner. IDs here are preorder positions, not revision IDs.
    mutating func table<Identity:Hashable>(identity:(EventStreamTransformedNode<Element>)->Identity)->EventStreamCollectedTreeTable<Identity> {
        if let cached=cachedTable as? EventStreamCollectedTreeTable<Identity> {return cached}
        var values:[Identity:Int]=[:],paths:[Int:[Int]]=[:],position=0
        var pending=roots.enumerated().reversed().map {($0.element,[$0.offset])}
        while let (item,path)=pending.popLast() {
            values[identity(item.node)]=position;paths[position]=path;position += 1
            pending.append(contentsOf:item.children.enumerated().reversed().map {($0.element,path+[$0.offset])})
        }
        let result=EventStreamCollectedTreeTable(values:values,paths:paths);cachedTable=result;return result
    }
    var preorder:[EventStreamCollectedItem<Element>] {
        var pending=Array(roots.reversed()),result:[EventStreamCollectedItem<Element>]=[]
        while let item=pending.popLast() {result.append(item);pending.append(contentsOf:item.children.reversed())}
        return result
    }
}

struct EventStreamCollectedTreeTable<Identity:Hashable> {
    let values:[Identity:Int]
    let elements:[Int:Identity]
    let paths:[Int:[Int]]
    init(values:[Identity:Int],paths:[Int:[Int]]) {
        self.values=values;self.paths=paths
        var inverse:[Int:Identity]=[:]
        for (identity,index) in values {inverse[index]=identity}
        elements=inverse
    }
}

@MainActor protocol EventStreamTreeCollectionBackend {
    associatedtype Element
    associatedtype Identity:Hashable
    func identity(_ element:Element) -> Identity
    func construct(_ element:Element,context:EventStreamNodeContext) -> EventStreamTransformedNode<Element>
    func children(_ element:Element,context:EventStreamNodeContext) -> EventStreamChildArray<Element>?
}

// Construct parent, select children, filter each child
// immediately before descent, then append the completed item. The visited set
// spans the whole add operation, including siblings; root is not filtered.
@MainActor struct EventStreamTreeCollection<Backend:EventStreamTreeCollectionBackend> {
    let backend:Backend
    private typealias Element=Backend.Element
    private typealias Item=EventStreamCollectedItem<Element>
    private final class Pending {
        let node:EventStreamTransformedNode<Element>,path:[Int],parent:Pending?
        let subset:EventStreamArraySubset?
        var children:[Item]=[]
        init(node:EventStreamTransformedNode<Element>,path:[Int],parent:Pending?,subset:EventStreamArraySubset?) {
            self.node=node;self.path=path;self.parent=parent;self.subset=subset
        }
    }
    private enum Work {
        case enter(Element,[Int],String?,Pending?)
        case child(Int,Element,[Int],Pending)
        case finish(Pending)
    }
    func collect(_ root:Backend.Element,context:EventStreamNodeContext = .init(),currentPath:[Int]=[],
                 filter:(Int,Backend.Element)->Bool = {_,_ in true}) -> EventStreamCollectedTree<Backend.Element> {
        collect(root,context:context,currentPath:currentPath,filter:filter,checkpoint:{})
    }
    func collect(_ root:Backend.Element,context:EventStreamNodeContext = .init(),currentPath:[Int]=[],
                 filter:(Int,Backend.Element)->Bool = {_,_ in true},
                 checkpoint:() throws -> Void) rethrows -> EventStreamCollectedTree<Backend.Element> {
        var visited:Set<Backend.Identity>=[],work:[Work]=[.enter(root,currentPath,context.parentRole,nil)]
        var roots:[Item]=[],duplicates=0,depthLimited=0
        while let step=work.popLast() {
            try checkpoint()
            switch step {
            case .child(let index,let element,let path,let parent):
                if filter(index,element) {work.append(.enter(element,path,parent.node.role,parent))}
            case .enter(let element,let path,let parentRole,let parent):
                guard path.count<201 else {depthLimited += 1;continue}
                guard visited.insert(backend.identity(element)).inserted else {duplicates += 1;continue}
                var nodeContext=context;nodeContext.parentRole=parentRole
                let node=backend.construct(element,context:nodeContext)
                let selected=backend.children(element,context:context)
                let pending=Pending(node:node,path:path,parent:parent,subset:selected?.subset)
                work.append(.finish(pending))
                if let children=selected?.elements {
                    for (index,child) in children.enumerated().reversed() {
                        work.append(.child(index,child,path+[index],pending))
                    }
                }
            case .finish(let pending):
                let item=Item(node:pending.node,path:pending.path,children:pending.children,childrenSubset:pending.subset)
                if let parent=pending.parent {parent.children.append(item)} else {roots.append(item)}
            }
        }
        return .init(roots:roots,duplicateReferencesSkipped:duplicates,depthLimitedReferencesSkipped:depthLimited)
    }
}
