import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct PIPPresentationAspect: Equatable, Sendable {
    let size: CGSize
    let reason: String
    let sourceSize: CGSize
}

/// Presentation aspect parsing from capture samples and the shared frame-status decoder.
enum PIPPresentationAspectParser {
    struct Dimensions: Sendable { let size: CGSize; let reason: String }

    static func normalizedMaximum(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 200 }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        return rounded >= 100 ? fmin(rounded, 400) : 100
    }
    static func fit(_ source: CGSize, maximum: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .init(width: 200, height: 200) }
        let maximum = normalizedMaximum(maximum)
        var ratio = maximum / source.width
        let heightRatio = maximum / source.height
        if heightRatio < ratio { ratio = heightRatio }
        // fmax keeps the numeric minimum when a product is NaN.
        return .init(width: fmax(source.width * ratio, 1), height: fmax(source.height * ratio, 1))
    }
    static func parse(maximum: CGFloat, dimensions: () -> Dimensions?,
                      attachments: () -> [SCStreamFrameInfo: Any]?) -> PIPPresentationAspect? {
        if let dimensions = dimensions(), dimensions.size.width > 0, dimensions.size.height > 0 {
            return .init(size: fit(dimensions.size, maximum: maximum), reason: dimensions.reason, sourceSize: dimensions.size)
        }
        guard let info = attachments() else { return nil }
        if let status = status(info), status != 0 && status != 4 { return nil }
        for (key, reason) in [(SCStreamFrameInfo.contentRect, "sample-content-rect"),
                              (SCStreamFrameInfo.boundingRect, "sample-bounding-rect")] {
            if let rectangle = rectangle(info[key]), CGRectGetWidth(rectangle) > 0, CGRectGetHeight(rectangle) > 0 {
                return .init(size: fit(rectangle.size, maximum: maximum), reason: reason, sourceSize: rectangle.size)
            }
        }
        return nil
    }
    static func status(_ info: [SCStreamFrameInfo: Any]) -> Int? {
        if let value = info[.status] as? SCFrameStatus { return value.rawValue }
        if let value = info[.status] as? Int { return value }
        if let value = info[.status] as? NSNumber { return value.intValue }
        return nil
    }
    static func rectangle(_ value: Any?) -> CGRect? {
        if let value = value as? CGRect { return value }
        if let value = value as? NSValue { return value.rectValue }
        return nil
    }
    static func nativeDimensions(_ sample: CMSampleBuffer) -> Dimensions? {
        if let image = CMSampleBufferGetImageBuffer(sample) {
            return .init(size: .init(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)), reason: "sample-image-buffer")
        }
        if let format = CMSampleBufferGetFormatDescription(sample) {
            // Deliberately no media-type guard here.
            let size = CMVideoFormatDescriptionGetDimensions(format)
            return .init(size: .init(width: Int(size.width), height: Int(size.height)), reason: "sample-format-description")
        }
        return nil
    }
    static func decodeFirstAttachments(_ raw: CFArray?) -> [SCStreamFrameInfo: Any]? {
        // Cast the entire array before selecting its first row.
        (raw as? [[SCStreamFrameInfo: Any]])?.first
    }
    static func firstAttachments(_ sample: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        decodeFirstAttachments(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false))
    }
    static func native(_ sample: CMSampleBuffer, maximum: CGFloat) -> PIPPresentationAspect? {
        parse(maximum: maximum, dimensions: { nativeDimensions(sample) }, attachments: { firstAttachments(sample) })
    }
}
