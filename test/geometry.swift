import Foundation
import CoreGraphics

@main
enum GeometryTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name)
            passed += 1
            print("PASS \(name)")
        }
        func geometry(_ frame: CGRect, _ width: Int, _ height: Int) -> ScreenshotGeometry {
            ScreenshotGeometry(windowID: 42, ownerPID: 123, screenFrame: frame, pixelWidth: width, pixelHeight: height)
        }
        let frame = CGRect(x: 310, y: 180, width: 600, height: 400)
        let retina = geometry(frame, 1200, 800)
        check("Retina image center maps to screen points", try retina.screenPoint(from: CGPoint(x: 600, y: 400)) == CGPoint(x: 610, y: 380))
        let points = geometry(frame, 600, 400)
        check("point-normalized image center has the same target", try points.screenPoint(from: CGPoint(x: 300, y: 200)) == CGPoint(x: 610, y: 380))
        let resized = geometry(frame, 300, 200)
        check("downscaled image maps back to the original window", try resized.screenPoint(from: CGPoint(x: 150, y: 100)) == CGPoint(x: 610, y: 380))
        let external = geometry(CGRect(x: -1920, y: -900, width: 900, height: 600), 1800, 1200)
        check("negative display origins stay global", try external.screenPoint(from: CGPoint(x: 400, y: 200)) == CGPoint(x: -1720, y: -800))
        let rounded = geometry(CGRect(x: 17, y: 33, width: 1001, height: 701), 1000, 700)
        let center = try rounded.screenPoint(from: CGPoint(x: 500, y: 350))
        check("integer image rounding does not shift the center", center == CGPoint(x: 517.5, y: 383.5))
        for point in [CGPoint(x: -1, y: 5), CGPoint(x: 1200, y: 2), CGPoint(x: 5, y: 800), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            do { _ = try retina.screenPoint(from: point); preconditionFailure("invalid coordinate accepted") }
            catch is ServiceError { passed += 1 }
        }
        let invalid = geometry(.zero, 0, 0)
        do { _ = try invalid.screenPoint(from: .zero); preconditionFailure("invalid geometry accepted") }
        catch is ServiceError { passed += 1 }
        let normal = ScreenshotGeometry.imageSize(frame: frame, backingScale: 2, sizing: .points)
        check("normalization does not upscale small windows", normal.width == 600 && normal.height == 400)
        let large = ScreenshotGeometry.imageSize(frame: CGRect(x: 0, y: 0, width: 3000, height: 2000), backingScale: 2, sizing: .points)
        check("short-edge cap preserves aspect", large.width == 1152 && large.height == 768)
        let wide = ScreenshotGeometry.imageSize(frame: CGRect(x: 0, y: 0, width: 6000, height: 1000), backingScale: 2, sizing: .points)
        check("long-edge cap applies to wide images", wide.width == 2048 && wide.height == 341)
        let native = ScreenshotGeometry.imageSize(frame: frame, backingScale: 2, sizing: .native)
        check("native mode retains Retina pixels", native.width == 1200 && native.height == 800)
        let fractional = CGRect(x: 0, y: 0, width: 600.125, height: 400.25)
        let onscreenSize = ScreenshotGeometry.nativeImageSize(frame: fractional, backingScale: 2, sizing: .native, offscreen: false)
        let offscreenSize = ScreenshotGeometry.nativeImageSize(frame: fractional, backingScale: 2, sizing: .native, offscreen: true)
        check("native ScreenCaptureKit dimensions round positive fractional pixels upward",
              onscreenSize?.width == 1201 && onscreenSize?.height == 801)
        check("native offscreen bitmap dimensions truncate fractional pixels",
              offscreenSize?.width == 1200 && offscreenSize?.height == 800)
        let nativeCapped = ScreenshotGeometry.nativeImageSize(frame: CGRect(x: 0, y: 0, width: 6000, height: 1000),
            backingScale: 2, sizing: .points, offscreen: false)
        check("native long-edge cap is applied before rounding", nativeCapped?.width == 2048 && nativeCapped?.height == 342)
        check("native capture rejects zero size, non-finite scale and pixel dimensions outside Int",
              ScreenshotGeometry.nativeImageSize(frame: .zero, backingScale: 2, sizing: .native, offscreen: false) == nil &&
              ScreenshotGeometry.nativeImageSize(frame: frame, backingScale: .infinity, sizing: .native, offscreen: false) == nil &&
              ScreenshotGeometry.nativeImageSize(frame: CGRect(x: 0, y: 0, width: CGFloat(Int.max), height: 8),
                  backingScale: 1, sizing: .native, offscreen: false) == nil)
        check("an offscreen resize smaller than one pixel falls back to its raw image",
              ScreenshotGeometry.nativeImageSize(frame: CGRect(x: 0, y: 0, width: 0.5, height: 2),
                  backingScale: 1, sizing: .native, offscreen: true) == nil)
        check("window movement invalidates coordinates", !ScreenshotGeometry.framesMatch(frame, frame.offsetBy(dx: 50, dy: 0)))
        check("window resize invalidates coordinates", !ScreenshotGeometry.framesMatch(frame, CGRect(x: 310, y: 180, width: 610, height: 400)))
        print("\(passed) geometry checks passed")
    }
}
