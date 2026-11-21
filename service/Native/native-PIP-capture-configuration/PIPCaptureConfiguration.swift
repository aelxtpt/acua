import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

@MainActor protocol PIPCaptureConfiguring: AnyObject {
    var pixelFormat: OSType { get set }
    var showsCursor: Bool { get set }
    var shouldBeOpaque: Bool { get set }
    var ignoreShadowsSingleWindow: Bool { get set }
    var ignoreShadowsDisplay: Bool { get set }
    var queueDepth: Int { get set }
    var minimumFrameInterval: CMTime { get set }
    var width: Int { get set }
    var height: Int { get set }
    var sourceRect: CGRect { get set }
}

extension SCStreamConfiguration: PIPCaptureConfiguring {}

/// Main and cursor capture configuration. Convert before clamping:
/// nonfinite/out-of-Int values trap, while finite zero/negative values yield 1.
@MainActor enum PIPCaptureConfiguration {
    nonisolated static func dimension(_ value: CGFloat) -> Int { max(1, Int(ceil(value))) }

    static func configure<Configuration: PIPCaptureConfiguring>(
        bounds: CGRect, scale: CGFloat, opaque: Bool? = nil, create: () -> Configuration
    ) -> Configuration {
        let configuration = create()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        if let opaque { configuration.shouldBeOpaque = opaque }
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        configuration.queueDepth = 5
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.width = dimension(CGRectGetWidth(bounds) * scale)
        // Keep the width setter before the height conversion/trap.
        configuration.height = dimension(CGRectGetHeight(bounds) * scale)
        return configuration
    }
    static func native(bounds: CGRect, scale: CGFloat, opaque: Bool? = nil) -> SCStreamConfiguration {
        configure(bounds: bounds, scale: scale, opaque: opaque, create: SCStreamConfiguration.init)
    }
}
