import Foundation

// Integer budget payload plus two distinct reasons.
enum EventStreamDifferenceLineBudgetExceeded:Equatable {
    case difference(Int)
    case removedElementSummary(Int)
}

struct EventStreamRenderInspectorPayload:Codable,Hashable {
    let current:EventStreamRenderSnapshot
    let previous:EventStreamRenderSnapshot?
    let first:EventStreamRenderSnapshot?
}

enum EventStreamRevisionDifferenceLines {
    // Comparison uses numeric snapshot identities, not the stored
    // native changes or an ancestry/subject-ID shortcut. Budget is the NEW
    // forest's node count. Count subtrees incrementally before formatting.
    static func build(old:EventStreamRenderedTree<Int>,new:EventStreamRenderedTree<Int>,
                      options:EventStreamRenderLineOptions,summarizesRemovedElementIDs:Bool,
                      ignoreDifferenceLineBudget:Bool,
                      onLineBudgetExceeded:(EventStreamDifferenceLineBudgetExceeded)->Void)->[String]? {
        let budget=new.preorder.count
        var remaining=budget,selected:[EventStreamRenderChange<Int>]=[],hasRemoval=false
        for change in EventStreamRenderDifference(oldTree:old,newTree:new) {
            if summarizesRemovedElementIDs && change.kind == .remove {
                hasRemoval=true;selected.append(change);continue
            }
            if !ignoreDifferenceLineBudget {
                var counter=change.lineCounter(options:options)
                let count=counter.increment(while:{$0<remaining})
                // Exact boundary: fixed counters may make remaining
                // negative; do not replace with a strict cost<=budget guard.
                if count==remaining && !counter.isEmpty {
                    onLineBudgetExceeded(.difference(budget));return nil
                }
                remaining -= counter.total()
            }
            selected.append(change)
        }
        // This gate is outside the ignore-ordinary-budget branch.
        if summarizesRemovedElementIDs && hasRemoval && remaining<1 {
            onLineBudgetExceeded(.removedElementSummary(budget));return nil
        }
        selected.sort {
            let order=IndexPath(indexes:$0.path).compare(IndexPath(indexes:$1.path))
            return order == .orderedSame ? $0.depthFirstRank<$1.depthFirstRank:order == .orderedAscending
        }
        var lines:[String]=[],removedIDs:[Int]=[]
        for change in selected {
            if summarizesRemovedElementIDs,case let .remove(_,cursor)=change {
                var work=[cursor.node]
                while let node=work.popLast() {
                    if let id=node.elementID {removedIDs.append(id)}
                    // The summary always expands the removed subtree, even
                    // when withoutRemovalSubtree suppresses its textual lines.
                    work.append(contentsOf:node.children)
                }
            } else {lines.append(contentsOf:change.lines(options:options))}
        }
        if !removedIDs.isEmpty {lines.append("Removed element IDs: "+removedIDRanges(removedIDs))}
        return lines
    }
    // Set first, sort signed Ints, compress inclusive
    // consecutive runs; duplicates disappear and runs are joined by comma-space.
    static func removedIDRanges(_ ids:[Int])->String {
        let sorted=Set(ids).sorted()
        guard var previous=sorted.first else {return ""}
        var start=previous,ranges:[String]=[]
        for id in sorted.dropFirst() {
            if id != previous+1 {ranges.append(start==previous ? "\(start)":"\(start)-\(previous)");start=id}
            previous=id
        }
        ranges.append(start==previous ? "\(start)":"\(start)-\(previous)")
        return ranges.joined(separator:", ")
    }
}

extension EventStreamTreeRevision {
    // Snapshot failures make the difference unavailable without a budget
    // callback. The old snapshot/rebuild precedes the current snapshot.
    func differenceLines(from previous:EventStreamTreeRevision,options:EventStreamRenderLineOptions,
                         summarizesRemovedElementIDs:Bool,ignoreDifferenceLineBudget:Bool,
                         onLineBudgetExceeded:(EventStreamDifferenceLineBudgetExceeded)->Void)->[String]? {
        guard let oldSnapshot=try? previous.renderTreeSnapshot() else {return nil}
        let old=oldSnapshot.renderTree()
        guard let currentSnapshot=try? renderTreeSnapshot() else {return nil}
        return EventStreamRevisionDifferenceLines.build(old:old,new:currentSnapshot.renderTree(),options:options,
            summarizesRemovedElementIDs:summarizesRemovedElementIDs,ignoreDifferenceLineBudget:ignoreDifferenceLineBudget,
            onLineBudgetExceeded:onLineBudgetExceeded)
    }
    // Current failure omits the entire payload. Previous/root
    // failures are independent optional omissions; equal FIRST/CURRENT values
    // suppress first, including when distinct revisions have equal snapshots.
    func renderTreeInspectorPayload()->EventStreamRenderInspectorPayload? {
        guard let current=try? renderTreeSnapshot() else {return nil}
        let previous=previousRevision.flatMap {try? $0.renderTreeSnapshot()}
        var first=try? lineageRootRevision.renderTreeSnapshot()
        if first==current {first=nil}
        return .init(current:current,previous:previous,first:first)
    }
}
