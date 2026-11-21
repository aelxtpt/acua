import CoreGraphics

/// Image absence and ordered comparisons matter.
struct SystemSettingsTransitionAppearance {
    let progress: Double
    let hasSourceImage: Bool
    let hasTargetImage: Bool

    init(progress: Double, hasSourceImage: Bool = true, hasTargetImage: Bool = true) {
        self.progress = progress
        self.hasSourceImage = hasSourceImage
        self.hasTargetImage = hasTargetImage
    }

    private var upperBounded: Double { progress > 1 ? 1 : progress }

    var sourceOpacity: Double {
        guard hasSourceImage else { return 0 }
        guard hasTargetImage else { return 1 }
        return progress <= 0 ? 1 : 1 - upperBounded
    }

    var targetOpacity: Double {
        guard hasTargetImage else { return 0 }
        guard hasSourceImage else { return 1 }
        let lowerBounded = progress <= 0 ? 0 : progress
        return lowerBounded > 1 ? 1 : lowerBounded
    }

    var sourceBlur: CGFloat {
        guard hasSourceImage && hasTargetImage else { return 0 }
        return progress <= 0 ? 0 : upperBounded * 12
    }

    var targetBlur: CGFloat {
        guard hasSourceImage && hasTargetImage else { return 0 }
        return progress <= 0 ? 12 : (1 - upperBounded) * 12
    }

    // Native shadow/stroke setters use a separate ordered clamp.
    private var layerProgress: Double { progress <= 0 ? 0 : upperBounded }
    var destinationShadowOpacity: Float { Float(layerProgress) }
    var strokeOpacity: Double { 0.15 * layerProgress }
}
