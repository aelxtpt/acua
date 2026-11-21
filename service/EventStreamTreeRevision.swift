import Foundation

//0x10065F708: revisions retain live render references and the previous revision.
// Snapshots below are separate values; automation TreeRevision is unrelated.
@MainActor final class EventStreamTreeRevision<Element,Identity:Hashable> {
    typealias Source=EventStreamCollectedTree<Element>
    typealias Render=EventStreamRenderedTree<Identity>
    let lineageID:String
    let tree:Source
    let renderTree:Render
    let focusTree:Source?
    let focusRenderTree:Render?
    let ids:EventStreamRenderIDTable<Identity>
    let changes:[EventStreamRenderChange<Identity>]
    let previousRevision:EventStreamTreeRevision?
    private let identity:(Element)->Identity

    init(tree:Source,renderTree:Render,focusTree:Source?=nil,focusRenderTree:Render?=nil,
         lineageID:String?=nil,changes:[EventStreamRenderChange<Identity>]=[],
         previousRevision:EventStreamTreeRevision?=nil,identity:@escaping (Element)->Identity) throws {
        // Table construction and its reference mutations precede lineage choice.
        let ids=try EventStreamRenderIDs.assign(main:renderTree,focus:focusRenderTree)
        self.ids=ids
        self.lineageID=previousRevision?.lineageID ?? lineageID ?? UUID().uuidString
        self.tree=tree;self.renderTree=renderTree;self.focusTree=focusTree;self.focusRenderTree=focusRenderTree
        self.changes=changes;self.previousRevision=previousRevision;self.identity=identity
    }
    //0x100661020: main render -> root numbering -> optional focus render ->
    // shared table. A later failure must not undo earlier node/context effects.
    static func root(_ tree:Source,focusTree:Source?=nil,lineageID:String,
                     identity:@escaping (Element)->Identity,render:(Source)throws->Render) throws->EventStreamTreeRevision {
        let main=try render(tree)
        EventStreamRenderIDs.setInitialIDs(main)
        let focus=try focusTree.map {try render($0)}
        return try .init(tree:tree,renderTree:main,focusTree:focusTree,focusRenderTree:focus,
                         lineageID:lineageID,identity:identity)
    }
    //0x1006608C8: only main trees are compared. Inherit ALL paired changes
    // before rendering focus; preserve the raw sibling-batch change order.
    func appending(tree:Source,focusTree:Source?=nil,render:(Source)throws->Render) throws->EventStreamTreeRevision {
        let main=try render(tree)
        let changes=EventStreamRenderDifference(oldTree:renderTree,newTree:main).buffer().changes
        for change in changes {change.inheritElementID()}
        let focus=try focusTree.map {try render($0)}
        return try .init(tree:tree,renderTree:main,focusTree:focusTree,focusRenderTree:focus,
                         changes:changes,previousRevision:self,identity:identity)
    }
    var lineageRootRevision:EventStreamTreeRevision {
        var root=self
        while let previous=root.previousRevision {root=previous}
        return root
    }
    func item(for id:Int)->EventStreamCollectedItem<Element>? {
        EventStreamRenderIDs.item(for:id,in:ids,tree:tree,focus:focusTree,identity:identity)
    }
    func element(for id:Int)->Element? {item(for:id)?.node.element}
    func renderTreeSnapshot() throws->EventStreamRenderSnapshot {try .capture(renderTree,subjectID:lineageID)}
    func focusRenderTreeSnapshot() throws->EventStreamRenderSnapshot? {
        try focusRenderTree.map {try .capture($0,subjectID:lineageID)}
    }
}
