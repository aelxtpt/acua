import CoreVideo
import Foundation
import QuartzCore

@MainActor final class RemoteHostedPIPCheckerboardRenderer {
    private enum Error: Swift.Error, CustomNSError {
        case couldNotCreateImage, couldNotCreatePixelBuffer
        static var errorDomain: String {
            let name = String(reflecting: Self.self)
            return "ComputerUse" + name[name.range(of: ".RemoteHostedPIPCheckerboardRenderer.")!.lowerBound...]
        }
        var errorCode: Int { self == .couldNotCreateImage ? 0 : 1 }
        var errorUserInfo: [String: Any] { [:] }
    }

    private let onPixelBuffer: (CVPixelBuffer) -> Void
    private var stripe: CALayer?
    init(onPixelBuffer: @escaping (CVPixelBuffer) -> Void) { self.onPixelBuffer = onPixelBuffer }

    static func normalizedMaxDisplaySize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 200 }
        return min(400, max(100, value.rounded(.toNearestOrAwayFromZero)))
    }

    func prepare(producer: RemoteHostedPIPContentProducer, isActive: Bool, maxDisplaySize: CGFloat) async throws -> CGSize {
        let side = Self.normalizedMaxDisplaySize(maxDisplaySize)
        try render(producer: producer, isActive: isActive, size: CGSize(width: side, height: side))
        return CGSize(width: side, height: side)
    }

    func resize(producer: RemoteHostedPIPContentProducer, isActive: Bool, size: CGSize) async throws {
        try render(producer: producer, isActive: isActive, size: size)
    }

    func stop() async {}

    // Fractional layer dimensions are preserved while the pixel
    // allocation converts each dimension to Int, including Swift's traps.
    func render(producer: RemoteHostedPIPContentProducer, isActive: Bool, size: CGSize) throws {
        let (image, pixelBuffer) = try Self.makeImage(isActive: isActive, size: size)
        let stripe = self.stripe ?? CALayer()
        stripe.frame = CGRect(x: -64, y: 0, width: 64, height: size.height)
        stripe.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
        self.stripe = stripe
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        producer.rootLayer.frame = CGRect(origin: .zero, size: size)
        producer.rootLayer.contents = image
        producer.rootLayer.contentsGravity = .resizeAspectFill
        producer.rootLayer.sublayers = [stripe]
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -64
        animation.toValue = size.width + 64
        animation.duration = 1.6
        animation.repeatCount = .infinity
        stripe.add(animation, forKey: "position.x")
        CATransaction.flush()
        onPixelBuffer(pixelBuffer)
    }

    private static func makeImage(isActive: Bool, size: CGSize) throws -> (CGImage, CVPixelBuffer) {
        let width = Int(size.width), height = Int(size.height)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw Error.couldNotCreatePixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw Error.couldNotCreateImage }
        let colors = isActive
            ? [CGColor(red: 0.04, green: 0.58, blue: 0.38, alpha: 1), CGColor(red: 0.13, green: 0.78, blue: 0.52, alpha: 1)]
            : [CGColor(red: 0.05, green: 0.34, blue: 0.84, alpha: 1), CGColor(red: 0.09, green: 0.62, blue: 0.95, alpha: 1)]
        for y in stride(from: 0, to: height, by: 48) {
            for x in stride(from: 0, to: width, by: 48) {
                context.setFillColor(colors[(x / 48 + y / 48) % colors.count])
                context.fill(CGRect(x: x, y: y, width: 48, height: 48))
            }
        }
        guard let image = context.makeImage() else { throw Error.couldNotCreateImage }
        return (image, buffer)
    }
}
