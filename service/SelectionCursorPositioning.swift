import Foundation
import CoreGraphics

enum SelectionCursorPositioning {
    // Use the range's lower-right corner, clamped
    // inclusively to the captured window. Zero-width caret rectangles work.
    static func point(bounds: CGRect, window: CGRect) -> CGPoint {
        let x = bounds.maxX > window.minX ? bounds.maxX : window.minX
        let y = bounds.maxY > window.minY ? bounds.maxY : window.minY
        return CGPoint(x: window.maxX >= x ? x : window.maxX,
                       y: window.maxY >= y ? y : window.maxY)
    }

    static func prepare(enabled: Bool, window: CGRect, checkpoint: () throws -> Void,
                        bounds: () -> CGRect?, scroll: (CGRect) throws -> Bool,
                        position: (CGPoint) throws -> Void) throws {
        guard enabled else { return }
        try checkpoint()
        guard let initial = bounds() else { try checkpoint(); return }
        try checkpoint()
        let scrolled = try scroll(initial)
        try checkpoint()
        // A failed/unsupported requery keeps the initial range rectangle.
        let final = scrolled ? (bounds() ?? initial) : initial
        try checkpoint()
        try position(point(bounds: final, window: window))
        try checkpoint()
    }
}
