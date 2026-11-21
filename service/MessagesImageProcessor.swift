import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MessagesImageProcessor {
    enum Failure: Error {
        case inputSizeOutOfRange, unsupportedImage, multipleImages, invalidDimensions
        case pixelCountOutOfRange, decodingFailed, encodingFailed, unableToFit
    }

    struct Image: Equatable {
        let data: Data
        let mimeType: String
    }

    static let maximumInputBytes = 64 * 1024 * 1024
    private static let maximumOutputBytes = 512 * 1024
    private static let maximumDimension = 2048
    private static let maximumPixels = 64_000_000

    static func process(_ data: Data) throws -> Image {
        guard (1...maximumInputBytes).contains(data.count) else { throw Failure.inputSizeOutOfRange }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { throw Failure.unsupportedImage }
        let mime: String?
        switch type {
        case UTType.jpeg.identifier: mime = "image/jpeg"
        case UTType.png.identifier: mime = "image/png"
        case UTType.webP.identifier: mime = "image/webp"
        case UTType.gif.identifier: mime = "image/gif"
        case UTType.heic.identifier, UTType.heif.identifier, "public.avif": mime = nil
        default: throw Failure.unsupportedImage
        }
        guard CGImageSourceGetCount(source) == 1 else { throw Failure.multipleImages }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.invalidDimensions }
        guard width <= maximumPixels / height else { throw Failure.pixelCountOutOfRange }

        if let mime, data.count <= maximumOutputBytes, max(width, height) <= maximumDimension {
            guard let validatingSource = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateImageAtIndex(validatingSource, 0,
                      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
                  CGImageSourceGetStatusAtIndex(validatingSource, 0) == .statusComplete else {
                throw Failure.decodingFailed
            }
            return Image(data: data, mimeType: mime)
        }

        var dimension = min(max(width, height), maximumDimension)
        for _ in 0..<3 {
            let image = try thumbnail(source, dimension: dimension)
            let first = try jpeg(image, quality: 0.85)
            if first.count <= maximumOutputBytes { return Image(data: first, mimeType: "image/jpeg") }
            let second = try jpeg(image, quality: 0.75)
            if second.count <= maximumOutputBytes { return Image(data: second, mimeType: "image/jpeg") }
            let size = Double(max(image.width, image.height))
            dimension = Int(floor(sqrt(Double(maximumOutputBytes) / Double(second.count)) * 0.95 * size))
            guard dimension >= 1 else { break }
        }
        throw Failure.unableToFit
    }

    private static func thumbnail(_ source: CGImageSource, dimension: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.decodingFailed }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let output = context.makeImage() else { throw Failure.decodingFailed }
        return output
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }
}
