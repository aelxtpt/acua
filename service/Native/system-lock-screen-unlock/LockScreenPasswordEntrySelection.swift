import Foundation
import CoreGraphics

enum LockScreenPasswordEntrySelection {
    static func index(in candidates: [LockScreenPasswordEntryCandidate], focusedUserFrame: CGRect) -> Int? {
        var best: (index: Int, below: CGFloat, horizontal: CGFloat)?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.role == "AXStaticText",
                  candidate.identifier == nil || candidate.identifier!.isEmpty,
                  let value = candidate.value, !value.isEmpty,
                  candidate.isEnabled != false, let frame = candidate.frame else { continue }
            let below = frame.minY - focusedUserFrame.maxY
            // Ordered comparisons: a NaN distance fails both bounds and is
            // rejected.
            guard below >= 0, below <= 120 else { continue }
            let horizontal = abs(frame.midX - focusedUserFrame.midX)
            guard horizontal <= 240 else { continue }
            if let previous = best {
                let better = below != previous.below ? below < previous.below : horizontal < previous.horizontal
                if better { best = (index, below, horizontal) }
            } else { best = (index, below, horizontal) }
        }
        return best?.index
    }
}
