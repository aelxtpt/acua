import Foundation

enum ControllerScreenshotSizing {
    struct Result: Sendable, Equatable { let size: CGSize; let pointScale: CGFloat }
    /// Update coordinate state before launching either capture child.
    /// Keep raw dimensions for native sizing; legacy invalid dimensions use 1x1.
    static func read(frame: CGRect, scale: CGFloat, legacy: Bool, normalizeToPoints: Bool) -> Result {
        var width = frame.width * scale, height = frame.height * scale
        var inverseFit: CGFloat = 1
        if legacy {
            let normalize = normalizeToPoints && scale > 1
            if normalize { width /= scale; height /= scale }
            if width > 0 && height > 0 {
                var long = 2048 / (width > height ? width : height)
                if long > 1 { long = 1 }
                let smaller = height * long < width * long ? height * long : width * long
                var short = 768 / smaller
                if short > 1 { short = 1 }
                let fit = long * short
                width *= fit; height *= fit
                inverseFit = 1 / fit
            } else { width = 1; height = 1 }
            if normalize { inverseFit *= scale }
        }
        return .init(size: .init(width: width, height: height), pointScale: inverseFit / scale)
    }
}
