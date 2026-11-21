import Foundation
import CoreGraphics

/// The captured window's global, y-down frame in points and the actual image
/// dimensions. Always keep these together; AX coordinates are already global.
struct ScreenshotGeometry {
    let windowID: UInt32
    let ownerPID: Int32
    let screenFrame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    var includedWindowIDs: [UInt32] = []
    var nativeLayout: NativeLayout?
    var pointerTarget: PointerTarget { PointerTarget(windowID: windowID, ownerPID: ownerPID, screenFrame: screenFrame) }

    // Coordinates are mapped before selecting from all app windows.
    // The point may lie beyond the last screenshot and hit another app window.
    func nativeScreenPoint(from point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else {
            throw ServiceError(.unhandledEvent, "Invalid pointer position")
        }
        let mapped: CGPoint
        if let nativeLayout {
            mapped = nativeLayout.screenPoint(from: point)
        } else {
            guard pixelWidth > 0, pixelHeight > 0, CaptureLayout.valid(screenFrame) else {
                throw ServiceError(.unhandledEvent, "Invalid coordinate geometry")
            }
            mapped = CGPoint(x: screenFrame.minX + point.x * screenFrame.width / CGFloat(pixelWidth),
                             y: screenFrame.minY + point.y * screenFrame.height / CGFloat(pixelHeight))
        }
        guard mapped.x.isFinite, mapped.y.isFinite else {
            throw ServiceError(.unhandledEvent, "Invalid pointer position")
        }
        return mapped
    }

    func screenPoint(from point: CGPoint) throws -> CGPoint {
        guard pixelWidth > 0, pixelHeight > 0,
              screenFrame.width.isFinite, screenFrame.height.isFinite,
              screenFrame.minX.isFinite, screenFrame.minY.isFinite,
              screenFrame.width > 0, screenFrame.height > 0,
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < CGFloat(pixelWidth), point.y < CGFloat(pixelHeight) else {
            throw ServiceError(.unhandledEvent, "Coordinate is outside the captured image")
        }
        if let nativeLayout {
            let mapped = nativeLayout.screenPoint(from: point)
            guard screenFrame.contains(mapped) else {
                throw ServiceError(.unhandledEvent, "Coordinate maps outside the captured window")
            }
            return mapped
        }
        // The local capture protocol scales from the delivered image dimensions.
        return CGPoint(x: screenFrame.minX + point.x * screenFrame.width / CGFloat(pixelWidth),
                       y: screenFrame.minY + point.y * screenFrame.height / CGFloat(pixelHeight))
    }

    enum Sizing: String {
        case points, native, legacy
    }

    /// Point-normalized or native pixel dimensions,
    /// with the optional 2048-long-edge / 768-short-edge cap, never upscaled.
    static func imageSize(frame: CGRect, backingScale: CGFloat, sizing: Sizing) -> (width: Int, height: Int) {
        guard let size = requestedSize(frame: frame, backingScale: backingScale, sizing: sizing),
              let width = Int(exactly: size.width.rounded()), let height = Int(exactly: size.height.rounded()) else { return (1, 1) }
        return (max(1, width), max(1, height))
    }

    struct NativeLayout {
        let requestedSize: CGSize
        let windowOrigin: CGPoint
        let pointScale: CGFloat
        let visibleSize: CGSize

        init(requestedSize: CGSize, windowOrigin: CGPoint, pointScale: CGFloat, visibleSize: CGSize? = nil) {
            self.requestedSize = requestedSize
            self.windowOrigin = windowOrigin
            self.pointScale = pointScale
            self.visibleSize = visibleSize ?? CGSize(width: requestedSize.width * pointScale,
                                                    height: requestedSize.height * pointScale)
        }

        // Controller initialization precedes any image plan.
        static var uninitialized: Self {
            Self(requestedSize: .zero, windowOrigin: CGRect.null.origin, pointScale: 0)
        }

        func screenPoint(from point: CGPoint) -> CGPoint {
            CGPoint(x: windowOrigin.x + point.x * pointScale,
                    y: windowOrigin.y + point.y * pointScale)
        }

    }

    // Keep a single coordinate scale before raster rounding.
    static func nativeLayout(frame: CGRect, backingScale: CGFloat, sizing: Sizing) -> NativeLayout? {
        guard backingScale.isFinite, backingScale > 0 else { return nil }
        var width = frame.width * backingScale, height = frame.height * backingScale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        if sizing == .points {
            width /= backingScale
            height /= backingScale
        }
        let fit = sizing == .native ? 1 : fittingScale(width: width, height: height)
        let size = CGSize(width: width * fit, height: height * fit)
        let pointScale = sizing == .points ? (1 / fit * backingScale) / backingScale : (1 / fit) / backingScale
        guard pointScale.isFinite, pointScale > 0 else { return nil }
        return NativeLayout(requestedSize: size, windowOrigin: frame.origin, pointScale: pointScale, visibleSize: frame.size)
    }

    // ScreenCaptureKit sizes use ceil. The explicit offscreen bitmap resize
    // truncates positive dimensions instead.
    static func nativeImageSize(frame: CGRect, backingScale: CGFloat, sizing: Sizing,
                                offscreen: Bool) -> (width: Int, height: Int)? {
        guard let layout = nativeLayout(frame: frame, backingScale: backingScale, sizing: sizing) else { return nil }
        return pixelSize(layout.requestedSize, offscreen: offscreen)
    }

    static func pixelSize(_ size: CGSize, offscreen: Bool) -> (width: Int, height: Int)? {
        let rounding: FloatingPointRoundingRule = offscreen ? .towardZero : .up
        guard let width = Int(exactly: size.width.rounded(rounding)), let height = Int(exactly: size.height.rounded(rounding)),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func requestedSize(frame: CGRect, backingScale: CGFloat, sizing: Sizing) -> CGSize? {
        let multiplier = sizing == .points ? 1 : backingScale
        let width = frame.width * multiplier, height = frame.height * multiplier
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let factor = sizing == .native ? 1 : fittingScale(width: width, height: height)
        return CGSize(width: width * factor, height: height * factor)
    }

    private static func fittingScale(width: CGFloat, height: CGFloat) -> CGFloat {
        let longEdge = min(1, 2048 / max(width, height))
        let shortEdge = min(1, 768 / (min(width, height) * longEdge))
        return longEdge * shortEdge
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 &&
        abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }
}

struct PointerTarget {
    let windowID: UInt32
    let ownerPID: Int32
    let screenFrame: CGRect
    // ViewBridge can display a host-owned window while a separate service
    // receives input, so the event target stores these independently.
    let eventPID: Int32
    let requireOnscreen: Bool

    init(windowID: UInt32, ownerPID: Int32, screenFrame: CGRect, eventPID: Int32? = nil, requireOnscreen: Bool = true) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.screenFrame = screenFrame
        self.eventPID = eventPID ?? ownerPID
        self.requireOnscreen = requireOnscreen
    }
}
