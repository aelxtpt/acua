import Foundation

// SystemSelection.LLMDescriptionMode and DifferenceBaseline reflection. These
// selectors are distinct from the two-case wire EventStreamAXTree.Mode.
enum EventStreamDifferenceBaseline {case initial,previous}
enum EventStreamSelectionDescriptionMode {case difference(from:EventStreamDifferenceBaseline),fullTree}

extension EventStreamTreeRevision {
    //0x100242A14: select predecessor/initial baseline, always summarize removed
    // IDs, fall back on unavailable difference, and preserve available-empty.
    func eventStreamDescription(_ mode:EventStreamSelectionDescriptionMode,lineOptions:EventStreamRenderLineOptions,
                                ignoreDifferenceLineBudget:Bool,
                                onLineBudgetExceeded:(EventStreamDifferenceLineBudgetExceeded)->Void={_ in})->String {
        if case let .difference(baseline)=mode,let previous=previousRevision {
            let from=baseline == .previous ? previous:previous.lineageRootRevision
            if let lines=differenceLines(from:from,options:lineOptions,summarizesRemovedElementIDs:true,
                ignoreDifferenceLineBudget:ignoreDifferenceLineBudget,onLineBudgetExceeded:onLineBudgetExceeded) {
                return lines.isEmpty ? "no_change":lines.joined(separator:"\n")
            }
        }
        return renderTree.lines(options:lineOptions).joined(separator:"\n")
    }
}
