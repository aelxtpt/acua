import CoreVideo
import CryptoKit
import Foundation
import QuartzCore

// Only logical BGRA pixels are compared; allocation padding is not image data.
enum CheckerboardFixture {
    static let cases: [(String, Bool, CGSize)] = {
        let sizes: [CGSize] = [.init(width: 1, height: 1), .init(width: 47, height: 49), .init(width: 48, height: 48), .init(width: 49, height: 47),
            .init(width: 96, height: 97), .init(width: 100, height: 100), .init(width: 145.75, height: 98.5), .init(width: 400, height: 203)]
        var result = [(String, Bool, CGSize)]()
        for active in [false, true] { for (i, size) in sizes.enumerated() { result.append(("render-\(active)-\(i)", active, size)) } }
        for (i, size) in [CGSize(width: 0, height: 10), .init(width: 10, height: 0), .zero, .init(width: -1, height: 10), .init(width: -0.5, height: 10), .init(width: 10, height: -1)].enumerated() {
            result.append(("invalid-size-\(i)", false, size))
        }
        result.append(("success-after-errors", false, .init(width: 99, height: 101)))
        return result
    }()
    static let normalizationValues: [Double] = [-Double.greatestFiniteMagnitude, -1.5, -0.0, 0, 99.49, 99.5, 100.49, 100.5,
        199.5, 200.49, 200.5, 399.49, 399.5, 400.5, Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan]
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func rect(_ value: CGRect) -> [Double] { [value.origin.x, value.origin.y, value.size.width, value.size.height] }
    static func logicalPixels(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        var bytes = Data()
        for y in 0..<height { bytes.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
        return bytes
    }
    static func imagePixels(_ image: CGImage) -> Data {
        let raw = image.dataProvider!.data! as Data
        var bytes = Data()
        for y in 0..<image.height { bytes.append(raw.subdata(in: y * image.bytesPerRow..<y * image.bytesPerRow + image.width * 4)) }
        return bytes
    }
    static func snapshot(root: CALayer, buffer: CVPixelBuffer?, previousStripe: CALayer?, previousBuffer: CVPixelBuffer?, error: Swift.Error?) -> [String: Any] {
        let stripe = root.sublayers?.first
        var result: [String: Any] = ["rootFrame": rect(root.frame), "rootBounds": rect(root.bounds), "contentsGravity": root.contentsGravity.rawValue,
            "sublayers": root.sublayers?.count ?? 0, "stripeReused": stripe != nil && stripe === previousStripe,
            "pixelBufferReused": buffer != nil && buffer === previousBuffer,
            "error": error.map { e in let e = e as NSError; return ["domain": e.domain, "code": e.code, "userInfo": e.userInfo] as [String: Any] } ?? NSNull()]
        if let stripe {
            result["stripeFrame"] = rect(stripe.frame)
            result["stripeColor"] = stripe.backgroundColor?.components?.map { Double($0) }
            result["animationKeys"] = (stripe.animationKeys() ?? []).sorted()
            if let a = stripe.animation(forKey: "position.x") as? CABasicAnimation {
                result["animation"] = ["keyPath": a.keyPath ?? "", "from": (a.fromValue as! NSNumber).doubleValue,
                    "to": (a.toValue as! NSNumber).doubleValue, "duration": a.duration, "repeatInfinite": a.repeatCount == .infinity,
                    "autoreverses": a.autoreverses, "removedOnCompletion": a.isRemovedOnCompletion,
                    "fillMode": a.fillMode.rawValue, "speed": a.speed, "additive": a.isAdditive, "cumulative": a.isCumulative] as [String: Any]
            }
        }
        if let value = root.contents {
            let image = value as! CGImage
            result["image"] = ["width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
                "bitsPerPixel": image.bitsPerPixel, "bytesPerRow": image.bytesPerRow, "bitmapInfo": image.bitmapInfo.rawValue,
                "colorModel": image.colorSpace!.model.rawValue, "logicalPixelSHA256": sha(imagePixels(image))] as [String: Any]
        }
        if let buffer {
            result["buffer"] = ["width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                "format": CVPixelBufferGetPixelFormatType(buffer), "bytesPerRow": CVPixelBufferGetBytesPerRow(buffer),
                "hasIOSurface": CVPixelBufferGetIOSurface(buffer) != nil, "planar": CVPixelBufferIsPlanar(buffer),
                "logicalPixelSHA256": sha(logicalPixels(buffer))] as [String: Any]
        }
        return result
    }
}
