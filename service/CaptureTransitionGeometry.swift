import Foundation
import CoreGraphics

/// Appshot geometry in AppKit screen coordinates. Pure calculations stay
/// separate from native windows and animation clocks, so they can be unit tested
/// without claiming that a rendered transition has been delivered.
enum CaptureTransitionGeometry {
    struct Screen: Equatable {
        let id: UInt32
        let frame: CGRect
        let scale: CGFloat
    }
    struct Destination: Equatable { let screen: Screen; let frame: CGRect }
    struct Metrics: Equatable {
        let springResponse: Double
        let dampingFraction: Double
        let animationDuration: Double
        let snapshotHeight: CGFloat
    }
    struct Insets: Equatable { let top, left, bottom, right: CGFloat }
    struct Shadow {
        var radius: CGFloat = 5
        var offsetY: CGFloat = -10
        var opacity: CGFloat = 0.3
    }
    struct Layout {
        let container: CGRect
        let image: CGRect
        let mask: CGRect
        let maskLocations: [CGFloat]
        let maskAlphas: [CGFloat]
        let icon: CGRect
        let title: CGRect?
        let cornerRadius, imageCornerRadius, shadowOpacity: CGFloat
    }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite) &&
            rect.width > 0 && rect.height > 0 && !rect.isNull && !rect.isInfinite
    }
    static func fromCG(_ frame: CGRect, primary: CGRect) -> CGRect? {
        guard valid(frame), valid(primary) else { return nil }
        let result = CGRect(x: frame.minX, y: primary.maxY - frame.maxY, width: frame.width, height: frame.height)
        return valid(result) ? result : nil
    }
    static func rect(_ value: AppCaptureWire.Rect) -> CGRect { CGRect(x: value.x, y: value.y, width: value.width, height: value.height) }

    /// Validate the supplied display and work area, select a live
    /// screen, clamp in the host's coordinate space, then map into AppKit.
    static func destination(_ target: AppCaptureWire.AnimationTarget, screens: [Screen], mainScreenID: UInt32?) -> Destination? {
        let destination = rect(target.destinationFrame), bounds = rect(target.agentDisplay.bounds), work = rect(target.agentDisplay.workArea)
        guard valid(destination), valid(bounds), valid(work), target.agentDisplay.scaleFactor.isFinite,
              target.agentDisplay.scaleFactor > 0 else { return nil }
        let live = screens.filter { valid($0.frame) && $0.scale.isFinite && $0.scale > 0 }
        guard let primary = live.first else { return nil }
        func intersecting(_ candidate: CGRect) -> Screen? {
            guard let converted = fromCG(candidate, primary: primary.frame) else { return nil }
            var best: Screen?, area: CGFloat = 0
            for screen in live {
                let intersection = screen.frame.intersection(converted)
                let next = intersection.isNull ? 0 : intersection.width * intersection.height
                // Keep the first screen on equal positive overlap.
                if next > area { area = next; best = screen }
            }
            return best
        }
        let byID = UInt32(exactly: target.agentDisplay.id).flatMap { id in live.first { $0.id == id } }
        guard let screen = byID ?? intersecting(destination) ?? intersecting(bounds) ?? live.first(where: { $0.id == mainScreenID }) else { return nil }
        let width = min(destination.width, work.width), height = min(destination.height, work.height)
        let x = min(max(destination.minX, work.minX), work.maxX - width)
        let y = min(max(destination.minY, work.minY), work.maxY - height)
        let result = CGRect(x: x - bounds.minX + screen.frame.minX,
                            y: bounds.height - (y - bounds.minY) - height + screen.frame.minY,
                            width: width, height: height)
        return valid(result) ? Destination(screen: screen, frame: result) : nil
    }
    static func title(window: String?, app: String?, style: AppCaptureWire.PresentationStyle) -> String? {
        guard style == .standard else { return nil }
        return [window, app].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
    static func cornerRadius(_ proposed: CGFloat?, frame: CGRect) -> CGFloat {
        guard valid(frame), let proposed, proposed.isFinite else { return 0 }
        // Only the upper bound is capped; negative inputs are retained.
        return min(proposed, min(frame.width, frame.height) * 0.5)
    }
    static func metrics(source: CGRect, destination: CGRect, style: AppCaptureWire.PresentationStyle,
                        hasTitle: Bool, fontHeight: CGFloat, scale: CGFloat) -> Metrics? {
        guard valid(source), valid(destination), fontHeight.isFinite, fontHeight >= 0, scale.isFinite, scale > 0 else { return nil }
        let distance = hypot(Double(source.midX - destination.midX), Double(source.midY - destination.midY))
        guard distance.isFinite else { return nil }
        let response = 0.57 - 0.2899999999999999 * exp(distance * -0.00035546009259484373)
        let extra = style == .standard && hasTitle ? ceil(fontHeight * scale) / scale + 4 : 0
        return Metrics(springResponse: response, dampingFraction: 0.73,
                       animationDuration: response * 3 + 0.15, snapshotHeight: ceil(destination.height + extra))
    }
    /// Native Animation.BezierFunction uses (.42,0,1,1) for ease-in and
    /// (.42,0,.58,1) for ease-in-out.
    static func fade(_ progress: Double, easeInOut: Bool = false) -> Double {
        let x = min(1, max(0, progress))
        if x == 0 || x == 1 { return x }
        let second = easeInOut ? 0.58 : 1.0
        var lower = 0.0, upper = 1.0
        for _ in 0..<30 {
            let t = (lower + upper) * 0.5, q = 1 - t
            let value = 3 * q * q * t * 0.42 + 3 * q * t * t * second + t * t * t
            if value < x { lower = t } else { upper = t }
        }
        let t = (lower + upper) * 0.5
        return 3 * (1 - t) * t * t + t * t * t
    }
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, valid(bounds) else { return bounds }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * factor, height = size.height * factor
        return CGRect(x: bounds.midX - width * 0.5, y: bounds.midY - height * 0.5, width: width, height: height)
    }
    /// Shadow insets: the sides and top grow with progress; the bottom stays 0.
    static func insets(size: CGSize, progress: CGFloat, shadow: Shadow) -> Insets {
        let p = min(1, max(0, progress)), extent = ceil(max(0, shadow.radius) * 4)
        let side = min(floor((size.width - 1) * 0.5), extent * p)
        let top = min(floor(size.height - 1), ceil(max(0, extent + shadow.offsetY)) * p)
        return Insets(top: top, left: side, bottom: 0, right: side)
    }
    static func maskLocations(image: CGRect?, mask: CGRect?) -> [CGFloat] {
        guard let image, let mask, valid(image), valid(mask) else { return [0, 0, 0.825, 0.95, 1, 1] }
        let start = min(1, max(0, (mask.maxY - image.maxY) / mask.height))
        let end = min(1, max(0, (mask.maxY - image.minY) / mask.height))
        return [0, start, start + (end - start) * 0.825, start + (end - start) * 0.95, end, 1]
    }
    /// The progress can overshoot one during the spring. Only
    /// mask/shadow inset progress is clamped, not the motion or scale curve.
    static func layout(source: CGRect, destination: CGRect, imageSize: CGSize, progress p: CGFloat,
                       initialCornerRadius: CGFloat, targetCornerRadius: CGFloat,
                       style: AppCaptureWire.PresentationStyle, hasTitle: Bool,
                       fontHeight: CGFloat, scale: CGFloat, shadow: Shadow = Shadow()) -> Layout? {
        guard valid(source), valid(destination), p.isFinite, initialCornerRadius.isFinite, targetCornerRadius.isFinite,
              fontHeight.isFinite, fontHeight >= 0, scale.isFinite, scale > 0,
              shadow.radius.isFinite, shadow.offsetY.isFinite, shadow.opacity.isFinite else { return nil }
        let sx = source.midX, sy = source.midY, tx = destination.midX, ty = destination.midY
        let cx = ((sx + tx) * 0.5 - sx * 0.25 - tx * 0.25) * 2
        let cy = (ty + (ty > sy ? 50 : -50) - sy * 0.25 - ty * 0.25) * 2
        let q = 1 - p, center = CGPoint(x: sx * q * q + 2 * p * q * cx + tx * p * p,
                                       y: sy * q * q + 2 * p * q * cy + ty * p * p)
        let bounce = 1 + (1 - p) * sin(p * .pi) * 0.12
        let width = (source.width + p * (destination.width - source.width)) * bounce
        let height = (source.height + p * (destination.height - source.height)) * bounce
        let container = CGRect(x: center.x - width * 0.5, y: center.y - height * 0.5, width: width, height: height)
        guard valid(container) else { return nil }
        let inset = insets(size: container.size, progress: p, shadow: shadow)
        let content = CGRect(x: inset.left, y: inset.bottom, width: max(1, width - inset.left - inset.right), height: max(1, height - inset.top - inset.bottom))
        let image = aspectFit(imageSize, in: style == .quickChat ? CGRect(origin: .zero, size: container.size) : content)
        let topShadow = ceil(max(0, ceil(max(0, shadow.radius) * 4) + shadow.offsetY))
        let bottomShadow = ceil(max(0, ceil(max(0, shadow.radius) * 4) - shadow.offsetY))
        let bottom = image.minY - bottomShadow
        let mask = CGRect(x: 0, y: bottom, width: width, height: max(1, min(height, image.maxY + topShadow) - bottom))
        let fade = p > 0.75 ? min(1, max(0, (p - 0.75) * 4)) : 0
        let titleHeight = ceil(fontHeight * scale) / scale, snap = max(1, scale)
        let title: CGRect? = style == .standard && hasTitle ? CGRect(
            x: round((container.midX - max(0, destination.width - 20) * 0.5) * snap) / snap,
            y: round((container.minY - 4 - titleHeight) * snap) / snap,
            width: round(max(0, destination.width - 20) * snap) / snap,
            height: round(titleHeight * snap) / snap) : nil
        let icon = style == .quickChat
            ? CGRect(x: width * 0.5 - 8, y: 4, width: 16, height: 16)
            : CGRect(x: image.midX - 12, y: mask.minY, width: 24, height: 24)
        let corner = initialCornerRadius + p * (targetCornerRadius - initialCornerRadius)
        let imageCorner = corner + p * (2 - corner)
        return Layout(container: container, image: image, mask: mask,
                      maskLocations: maskLocations(image: image, mask: mask), maskAlphas: [1, 1, 1 - 0.79 * fade, 1 - fade, 1 - fade, 1 - fade],
                      icon: icon, title: title, cornerRadius: corner, imageCornerRadius: imageCorner,
                      shadowOpacity: style == .quickChat ? 0 : min(1, max(0, shadow.opacity)) * p)
    }
}

/// Known states and events of a capture transition.
/// The native driver must act on these effects; this does not animate a window.
struct CaptureTransitionLifecycle {
    enum Phase { case created, opening, opened, moving, arrived, cancelled }
    enum Event { case start, openingFinished, moveFinished, complete, cancel }
    enum Effect: Equatable { case open, move, wakeMoveWaiters, close }
    private(set) var phase: Phase = .created
    private(set) var completionRequested = false
    mutating func send(_ event: Event) -> [Effect] {
        if phase == .cancelled { return [] }
        switch event {
        case .start:
            guard phase == .created else { return [] }; phase = .opening; return [.open]
        case .openingFinished:
            guard phase == .opening else { return [] }; phase = .opened
            phase = .moving; return [.move]
        case .moveFinished:
            guard phase == .moving else { return [] }; phase = .arrived
            if completionRequested { phase = .cancelled; return [.wakeMoveWaiters, .close] }
            return [.wakeMoveWaiters]
        case .complete:
            completionRequested = true
            if phase == .arrived { phase = .cancelled; return [.wakeMoveWaiters, .close] }
            return []
        case .cancel:
            phase = .cancelled; return [.wakeMoveWaiters, .close]
        }
    }
}
