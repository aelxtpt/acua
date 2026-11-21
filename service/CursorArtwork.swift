import AppKit
import QuartzCore

/// Approved cursor artwork shared by the native service and component fixtures.
enum CursorArtwork {
    static let onScreenHeight: CGFloat = 16.5
    static let drawingInset: CGFloat = 12
    static let motionGlowName = "motionGlow"
    static let agentLabelName = "agentLabel"

    struct CursorLayout {
        let canvasSize: CGSize
        let cursorRect: CGRect
        let labelRect: CGRect
        let hotspot: CGPoint
    }

    static func cursorLayout(scale: CGFloat = 1) -> CursorLayout {
        let geometry = cursorGeometry()
        let height = onScreenHeight * scale
        let width = height * geometry.boxSize.width / geometry.boxSize.height
        let inset = drawingInset * scale
        let labelSize = CGSize(width: 46 * scale, height: 19 * scale)
        let canvas = CGSize(width: max(width, labelSize.width) + inset * 2,
                            height: height + 5 * scale + labelSize.height + inset * 2)
        let cursor = CGRect(x: (canvas.width - width) / 2,
                            y: inset + labelSize.height + 5 * scale, width: width, height: height)
        return CursorLayout(canvasSize: canvas, cursorRect: cursor,
                            labelRect: CGRect(x: (canvas.width - labelSize.width) / 2, y: inset,
                                              width: labelSize.width, height: labelSize.height),
                            hotspot: CGPoint(x: cursor.minX + geometry.tipFraction.x * width,
                                             y: cursor.minY + geometry.tipFraction.y * height))
    }

    /// Keep the rounded navigation-arrow design. Each rear wing and its curve
    /// are an exact reflection of the other across x=y in the source path.
    static let baseOrientationDegrees: CGFloat = 0

    private static func rawPath(_ rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        let path = CGMutablePath()
        path.move(to: p(0.006, 0.1586))
        path.addCurve(to: p(0.1586, 0.006), control1: p(-0.0236, 0.0646), control2: p(0.0646, -0.0236))
        path.addLine(to: p(0.90, 0.25))
        path.addCurve(to: p(0.90, 0.48), control1: p(1.00, 0.285), control2: p(1.00, 0.435))
        path.addLine(to: p(0.60, 0.60))
        path.addLine(to: p(0.48, 0.90))
        path.addCurve(to: p(0.25, 0.90), control1: p(0.435, 1.00), control2: p(0.285, 1.00))
        path.closeSubpath()
        return path
    }

    /// Flip the y-down source into AppKit coordinates with uniform proportions.
    static func cursorGeometry() -> (path: CGPath, boxSize: CGSize, tipFraction: CGPoint) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)
        let rotate = CGAffineTransform(rotationAngle: baseOrientationDegrees * .pi / 180)
        var transform = flip.concatenating(rotate)
        let path = rawPath(unit).copy(using: &transform)!
        let box = path.boundingBoxOfPath
        var translation = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let moved = path.copy(using: &translation)!
        // Midpoint of the rounded nose, rather than one side of its curve.
        var tip = CGPoint(x: 0.03595, y: 0.03595).applying(transform)
        tip = CGPoint(x: tip.x - box.minX, y: tip.y - box.minY)
        return (moved, box.size, CGPoint(x: tip.x / box.width, y: tip.y / box.height))
    }

    /// Backwards-compatible helper used by tests/tools.
    static func agentCursorPath(in rect: CGRect) -> CGPath {
        let geometry = cursorGeometry()
        var scale = CGAffineTransform(scaleX: rect.width / geometry.boxSize.width,
                                      y: rect.height / geometry.boxSize.height)
        let path = geometry.path.copy(using: &scale)!
        var translation = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        return path.copy(using: &translation)!
    }

    /// Shared by the live window and the offscreen visual review.
    static func makeCursorArtwork(scale: CGFloat = 1, glowIntensity: Float = 0) -> CALayer {
        let layout = cursorLayout(scale: scale)
        let arrowScale = scale * onScreenHeight / 25
        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: layout.canvasSize)
        root.anchorPoint = CGPoint(x: layout.hotspot.x / layout.canvasSize.width,
                                   y: layout.hotspot.y / layout.canvasSize.height)
        let path = agentCursorPath(in: layout.cursorRect)
        let pixelScale = NSScreen.main?.backingScaleFactor ?? 2
        root.contentsScale = pixelScale

        // Behind the solid artwork: only the soft halo is visible outside it.
        let glow = CAShapeLayer()
        glow.name = motionGlowName
        glow.frame = root.bounds
        glow.path = path
        let glowColor = NSColor(calibratedRed: 0.68, green: 0.63, blue: 1, alpha: 1).cgColor
        glow.fillColor = glowColor
        glow.shadowPath = path
        glow.shadowColor = glowColor
        glow.shadowOpacity = 0.85
        glow.shadowRadius = 4 * arrowScale
        glow.shadowOffset = .zero
        glow.opacity = min(max(glowIntensity, 0), 1)
        glow.contentsScale = pixelScale
        root.addSublayer(glow)

        // A narrow dark rim keeps the white edge legible on light surfaces.
        let rim = CAShapeLayer()
        rim.frame = root.bounds
        rim.path = path
        rim.fillColor = NSColor(calibratedWhite: 0.16, alpha: 0.88).cgColor
        rim.strokeColor = NSColor(calibratedWhite: 0.12, alpha: 0.52).cgColor
        rim.lineWidth = 2.2 * arrowScale
        rim.lineJoin = .round
        rim.shadowPath = path
        rim.shadowColor = NSColor.black.cgColor
        rim.shadowOpacity = 0.22
        rim.shadowRadius = 2.5 * arrowScale
        rim.shadowOffset = CGSize(width: 0, height: -1.5 * arrowScale)
        rim.contentsScale = pixelScale
        root.addSublayer(rim)

        let fill = CAGradientLayer()
        fill.frame = layout.cursorRect
        fill.colors = [
            NSColor(calibratedRed: 0.99, green: 0.99, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.93, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.67, green: 0.69, blue: 0.83, alpha: 1).cgColor,
        ]
        fill.locations = [0, 0.55, 1]
        fill.startPoint = CGPoint(x: 0.15, y: 1)
        fill.endPoint = CGPoint(x: 0.85, y: 0)
        let mask = CAShapeLayer()
        mask.frame = fill.bounds
        mask.path = agentCursorPath(in: fill.bounds)
        mask.fillColor = NSColor.white.cgColor
        mask.contentsScale = pixelScale
        fill.mask = mask
        root.addSublayer(fill)

        let edge = CAShapeLayer()
        edge.frame = root.bounds
        edge.path = path
        edge.fillColor = nil
        edge.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.95).cgColor
        edge.lineWidth = 0.9 * arrowScale
        edge.lineJoin = .round
        edge.contentsScale = pixelScale
        root.addSublayer(edge)

        let label = CALayer()
        label.name = agentLabelName
        label.frame = layout.labelRect
        label.cornerRadius = layout.labelRect.height / 2
        label.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.17, alpha: 0.94).cgColor
        label.borderColor = NSColor(calibratedRed: 0.86, green: 0.84, blue: 1, alpha: 0.3).cgColor
        label.borderWidth = 0.75 * scale
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.18
        label.shadowRadius = 2 * scale
        label.shadowOffset = CGSize(width: 0, height: -scale)
        label.shadowPath = CGPath(roundedRect: label.bounds, cornerWidth: label.cornerRadius,
                                  cornerHeight: label.cornerRadius, transform: nil)
        label.contentsScale = pixelScale
        let text = CATextLayer()
        text.string = NSAttributedString(string: "Agent", attributes: [
            .font: NSFont.systemFont(ofSize: 10 * scale, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.98, alpha: 1),
        ])
        text.alignmentMode = .center
        text.frame = CGRect(x: 0, y: 3 * scale, width: label.bounds.width, height: 13 * scale)
        text.contentsScale = pixelScale
        label.addSublayer(text)
        root.addSublayer(label)
        return root
    }

}
