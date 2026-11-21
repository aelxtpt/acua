import CoreGraphics
import Foundation

struct PIPCaptureKey: Equatable, Sendable {
    let windowIDs: [UInt32]
    let displayID: UInt32?
    let sourceRect: CGRect
    let pixelSize: CGSize
    static func == (left: Self, right: Self) -> Bool {
        left.windowIDs == right.windowIDs && left.displayID == right.displayID &&
            CGRectEqualToRect(left.sourceRect, right.sourceRect) &&
            left.pixelSize.width == right.pixelSize.width && left.pixelSize.height == right.pixelSize.height
    }
}
enum PIPCaptureFactoryError: Error { case sourceWindowUnavailable }

/// Native getters are injected so evaluation order, duplicates,
/// fresh lookups and configuration readback are shared with controlled checks.
@MainActor struct PIPCaptureFactory<Window, Display, Source, Filter, Configuration: PIPCaptureConfiguring> {
    struct Environment {
        let windows: () -> [Window]
        let displays: () -> [Display]
        let windowID: (Window) -> UInt32
        let windowFrame: (Window) -> CGRect
        let isOnScreen: (Window) -> Bool
        let hasOwner: (Window) -> Bool
        let processIdentifier: (Window) -> Int32?
        let source: (UInt32) -> Source?
        let bounds: (Source) -> CGRect
        let scale: (Source) -> CGFloat
        let displayFrame: (Display) -> CGRect
        let displayID: (Display) -> UInt32
        let independentFilter: (Window) -> Filter
        let displayFilter: (Display, [Window]) -> Filter
        let pointPixelScale: (Filter) -> Float
        let configuration: (CGRect, CGFloat) -> Configuration
    }
    struct Result {
        let primary: Window
        let filter: Filter
        let configuration: Configuration
        let targetBounds: CGRect
        let key: PIPCaptureKey
    }
    let environment: Environment

    private func sourceGeometry(_ id: UInt32) throws -> (CGRect, CGFloat) {
        guard let source = environment.source(id) else { throw PIPCaptureFactoryError.sourceWindowUnavailable }
        let bounds = environment.bounds(source)
        let scale = environment.scale(source)
        return (bounds, scale > 1 ? scale : 1)
    }
    func make(windowID: UInt32, associatedWindowIDs: [UInt32]) throws -> Result {
        let api = environment
        guard let primary = api.windows().first(where: { api.windowID($0) == windowID }) else {
            throw PIPCaptureFactoryError.sourceWindowUnavailable
        }
        let (primaryBounds, independentScale) = try sourceGeometry(windowID)
        let associated = api.windows().filter { candidate in
            guard associatedWindowIDs.contains(api.windowID(candidate)), api.isOnScreen(candidate), api.hasOwner(primary) else { return false }
            let candidatePID = api.processIdentifier(candidate)
            let primaryPID = api.processIdentifier(primary)
            return candidatePID == primaryPID
        }
        let filter: Filter
        let configuration: Configuration
        let target: CGRect
        let identifiers: [UInt32]
        let displayID: UInt32?
        if !associated.isEmpty,
           let display = PIPCaptureScreenSelection.bestDisplay(api.displays(), target: primaryBounds,
                                                              reference: primaryBounds, frame: api.displayFrame) {
            var union = primaryBounds
            for window in associated { union = CGRectUnion(union, api.windowFrame(window)) }
            target = CGRectIntersection(union, api.displayFrame(display))
            let included = [primary] + associated
            filter = api.displayFilter(display, included)
            configuration = api.configuration(target, CGFloat(api.pointPixelScale(filter)))
            let crop = CGRectOffset(target, -CGRectGetMinX(api.displayFrame(display)),
                                    -CGRectGetMinY(api.displayFrame(display)))
            configuration.sourceRect = crop
            configuration.shouldBeOpaque = false
            identifiers = included.map(api.windowID)
            displayID = api.displayID(display)
        } else {
            target = primaryBounds
            filter = api.independentFilter(primary)
            configuration = api.configuration(primaryBounds, independentScale)
            identifiers = [api.windowID(primary)]
            displayID = nil
        }
        // Sorting preserves duplicates; opacity is not part of the capture key.
        let sorted = identifiers.sorted()
        let rectangle = configuration.sourceRect
        let width = configuration.width
        let height = configuration.height
        return .init(primary: primary, filter: filter, configuration: configuration, targetBounds: target,
            key: .init(windowIDs: sorted, displayID: displayID, sourceRect: rectangle,
                       pixelSize: .init(width: width, height: height)))
    }
}
