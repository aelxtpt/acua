import AppKit

/// Preserve source order for equal scores.
@MainActor enum PIPCaptureScreenSelection {
    static func area(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = CGRectIntersection(left, right)
        return CGRectGetWidth(intersection) * CGRectGetHeight(intersection)
    }
    private static func firstMaximum<Value>(_ values: [(Value, CGFloat)]) -> Value? {
        guard var best = values.first else { return nil }
        for candidate in values.dropFirst() where best.1 < candidate.1 { best = candidate }
        return best.0
    }
    static func bestScreen<Screen>(for bounds: CGRect, preferred: Screen?, screens: () -> [Screen],
                                   frame: (Screen) -> CGRect) -> Screen? {
        if let preferred, CGRectIntersectsRect(frame(preferred), bounds) { return preferred }
        return firstMaximum(screens().map { ($0, area(frame($0), bounds)) })
    }
    static func bestDisplay<Display>(_ displays: [Display], target: CGRect, reference: CGRect,
                                     frame: (Display) -> CGRect) -> Display? {
        let references = displays.map { ($0, area(reference, frame($0))) }.filter { $0.1 > 0 }
        if let best = firstMaximum(references), CGRectIntersectsRect(frame(best), target) { return best }
        return firstMaximum(displays.map { ($0, area(target, frame($0))) }.filter { $0.1 > 0 })
    }
    static func nativeScale(for bounds: CGRect) -> CGFloat {
        // No preferred screen; the scale is 2 when no screen is present.
        // These frames are compared directly; do not add an axis flip.
        bestScreen(for: bounds, preferred: Optional<NSScreen>.none,
                   screens: { NSScreen.screens }, frame: { $0.frame })?.backingScaleFactor ?? 2
    }
}
