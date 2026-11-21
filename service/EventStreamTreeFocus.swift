import Foundation

@MainActor enum EventStreamTreeFocus {
    //0x10065B5A4: independent focus is the outer root, with selected items
    // as a new, unfocused child tree. Input hierarchy/caches are not reused.
    static func wrap<Element>(_ tree:EventStreamCollectedTree<Element>,
                              selectedItems:[EventStreamCollectedItem<Element>])->EventStreamCollectedTree<Element>? {
        guard let focused=tree.focusedElement else {return nil}
        return .init(roots:[.init(node:focused,path:[],children:selectedItems,childrenSubset:nil)],focusedElement:focused)
    }
    //0x1007714C4: reuse selected nodes only if every source resolves. Stop at
    // the first miss and recapture ALL selected sources, retaining duplicates
    // and order. Each reused node loses its old subtree/subset metadata.
    static func make<Element,Identity:Hashable>(
        _ tree:inout EventStreamCollectedTree<Element>,
        selected:(EventStreamTransformedNode<Element>)->[Element]?,identity:(Element)->Identity,
        recapture:(Element)->EventStreamCollectedTree<Element>
    )->EventStreamCollectedTree<Element>? {
        guard let focused=tree.focusedElement else {return nil}
        guard let sources=selected(focused) else {return wrap(tree,selectedItems:[])}
        var items:[EventStreamCollectedItem<Element>]=[],allFound=true
        for source in sources {
            let table=tree.table(identity:{identity($0.element)})
            guard let position=table.values[identity(source)],let path=table.paths[position],
                  let existing=item(in:tree,path:path) else {allFound=false;break}
            items.append(.init(node:existing.node,path:existing.path,children:[],childrenSubset:nil))
        }
        if !allFound {items=sources.flatMap {recapture($0).roots}}
        return wrap(tree,selectedItems:items)
    }
    private static func item<Element>(in tree:EventStreamCollectedTree<Element>,path:[Int])->EventStreamCollectedItem<Element>? {
        guard let index=path.first,tree.roots.indices.contains(index) else {return nil}
        var result=tree.roots[index]
        for index in path.dropFirst() {
            guard result.children.indices.contains(index) else {return nil}
            result=result.children[index]
        }
        return result
    }
}
