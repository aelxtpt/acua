import CoreGraphics
import Foundation

struct PIPCursorCaptureKey: Equatable, Sendable {
    let windowID: UInt32
    let displayID: UInt32
    let sourceRect: CGRect
    let pixelSize: CGSize
    static func == (a: Self, b: Self) -> Bool {
        a.windowID == b.windowID && a.displayID == b.displayID &&
            CGRectEqualToRect(a.sourceRect,b.sourceRect) &&
            a.pixelSize.width == b.pixelSize.width && a.pixelSize.height == b.pixelSize.height
    }
}

struct PIPCursorLayerGeometry: Sendable, Equatable {
    let targetBounds: CGRect
    let clippedBounds: CGRect

    /// An absent superlayer leaves the layer alone. Nonpositive extents hide
    /// and flush; unordered (NaN) comparisons deliberately fall through to a frame.
    enum Layout: Equatable { case unchanged, hidden, frame(CGRect) }
    func layout(superlayerBounds: CGRect?) -> Layout {
        guard let bounds=superlayerBounds else { return .unchanged }
        if bounds.width <= 0 || bounds.height <= 0 ||
            CGRectGetWidth(targetBounds) <= 0 || CGRectGetHeight(targetBounds) <= 0 { return .hidden }
        let x=bounds.width/CGRectGetWidth(targetBounds)
        let y=bounds.height/CGRectGetHeight(targetBounds)
        return .frame(.init(x:x*(CGRectGetMinX(clippedBounds)-CGRectGetMinX(targetBounds)),
            y:y*(CGRectGetMaxY(targetBounds)-CGRectGetMaxY(clippedBounds)),
            width:x*CGRectGetWidth(clippedBounds),height:y*CGRectGetHeight(clippedBounds)))
    }
}

/// SC content has already been obtained before bounds/cursor selection.
@MainActor struct PIPCursorCaptureFactory<Cursor,Window,Display,Filter,Configuration:PIPCaptureConfiguring> {
    struct Environment {
        let fallbackBounds: (UInt32) throws -> CGRect
        let cursors: () -> [Cursor]
        let targetWindowID: (Cursor) -> UInt32?
        let isVisible: (Cursor) -> Bool
        let windowNumber: (Cursor) -> Int
        let windows: () -> [Window]
        let windowID: (Window) -> UInt32
        let windowFrame: (Window) -> CGRect
        let displays: () -> [Display]
        let displayFrame: (Display) -> CGRect
        let displayID: (Display) -> UInt32
        let filter: (Display,[Window]) -> Filter
        let pointPixelScale: (Filter) -> Float
        let configuration: (CGRect,CGFloat) -> Configuration
    }
    struct Result {
        let filter: Filter
        let configuration: Configuration
        let key: PIPCursorCaptureKey
        let geometry: PIPCursorLayerGeometry
    }
    let environment: Environment
    func make(windowID: UInt32,targetBounds: CGRect?) throws -> Result? {
        let api=environment
        let target=try targetBounds ?? api.fallbackBounds(windowID)
        guard let cursor=api.cursors().first(where:{ api.targetWindowID($0)==windowID && api.isVisible($0) }) else { return nil }
        guard api.windowNumber(cursor)>=1 else { return nil }
        // The second getter is checked independently; do not narrow the first.
        let identifier=UInt32(api.windowNumber(cursor))
        guard let window=api.windows().first(where:{ api.windowID($0)==identifier }) else { return nil }
        let reference=api.windowFrame(window)
        guard let display=PIPCaptureScreenSelection.bestDisplay(api.displays(),target:target,reference:reference,frame:api.displayFrame) else { return nil }
        let clipped=CGRectIntersection(target,api.displayFrame(display))
        guard !CGRectIsNull(clipped),CGRectGetWidth(clipped)>0,CGRectGetHeight(clipped)>0 else { return nil }
        let filter=api.filter(display,[window])
        let crop=CGRectOffset(clipped,-CGRectGetMinX(api.displayFrame(display)),-CGRectGetMinY(api.displayFrame(display)))
        let configuration=api.configuration(clipped,CGFloat(api.pointPixelScale(filter)))
        configuration.sourceRect=crop
        let displayID=api.displayID(display)
        let width=configuration.width,height=configuration.height
        return .init(filter:filter,configuration:configuration,
            key:.init(windowID:identifier,displayID:displayID,sourceRect:crop,pixelSize:.init(width:width,height:height)),
            geometry:.init(targetBounds:target,clippedBounds:clipped))
    }
}
