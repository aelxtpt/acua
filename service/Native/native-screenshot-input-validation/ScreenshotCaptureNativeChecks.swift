import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenshotCaptureNativeChecks {
    static func run(output: URL) throws -> Int32 {
        var checks: [[String:Any]]=[]
        func check(_ name: String, _ passed: Bool) { checks.append(["name":name,"passed":passed]); if !passed { print("FAIL: "+name) } }
        let backend=ControllerScreenshotCaptureNative()
        for (opaque,shadow) in [(true,false),(false,true)] {
            let configuration=backend.configuration(opaque:opaque,includeWindowShadow:shadow)
            check("native configuration opaque flag \(opaque)",configuration.value.shouldBeOpaque==opaque)
            check("native single-window shadow flag \(shadow)",configuration.value.ignoreShadowsSingleWindow == !shadow)
            check("native display shadow and cursor flags \(opaque)",configuration.value.ignoreShadowsDisplay && !configuration.value.showsCursor)
            backend.setSize(configuration,width:123,height:87)
            check("native configuration receives integer dimensions \(opaque)",configuration.value.width==123 && configuration.value.height==87)
            let rect=CGRect(x:-31,y:47,width:91,height:107)
            backend.setSourceRect(configuration,rect)
            check("native configuration retains display-relative source rectangle \(opaque)",configuration.value.sourceRect==rect)
            let defaults=SCStreamConfiguration()
            check("native configuration preserves other framework defaults \(opaque)",configuration.value.scalesToFit==defaults.scalesToFit && configuration.value.ignoreGlobalClipSingleWindow==defaults.ignoreGlobalClipSingleWindow && configuration.value.includeChildWindows==defaults.includeChildWindows)
        }
        let context=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.6,alpha:1));context.fill(.init(x:0,y:0,width:2,height:2))
        let image=context.makeImage()!
        check("native resize retains an image with exactly matching size",ControllerScreenshotImageResize.resize(image,to:.init(width:2,height:2)) === image)
        let small=ControllerScreenshotImageResize.resize(image,to:.init(width:1.9,height:1.9))
        check("native resize truncates fractional output dimensions",small?.width==1 && small?.height==1)
        let sameRounded=ControllerScreenshotImageResize.resize(image,to:.init(width:2.9,height:2.9))
        check("native resize compares requested size before truncating",sameRounded != nil && sameRounded !== image && sameRounded?.width==2 && sameRounded?.height==2)
        let larger=ControllerScreenshotImageResize.resize(image,to:.init(width:3.9,height:4.9))
        check("native resize draws into the truncated bitmap dimensions",larger?.width==3 && larger?.height==4 && larger?.bitsPerComponent==image.bitsPerComponent)
        let unusableSizes: [CGSize] = [
            .init(width: CGFloat.nan, height: 1), .init(width: 1, height: CGFloat.infinity),
            .init(width: CGFloat(Int.max), height: 1), .init(width: 1, height: CGFloat(Int.max)),
            .init(width: -1, height: 2), .init(width: 2, height: 0.9)
        ]
        for size in unusableSizes {
            check("unusable offscreen resize keeps the raw buffer \(size)",
                  ControllerScreenshotImageResize.resize(image, to: size) == nil)
        }
        let data=Data([0,127,255,127])
        let mask=CGImage(maskWidth:2,height:2,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:2,
            provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false)!
        check("owned image-mask fixture has no color space",mask.colorSpace==nil)
        check("native resize rejects missing color space even at matching dimensions",ControllerScreenshotImageResize.resize(mask,to:.init(width:2,height:2))==nil)
        check("native resize rejects missing color space before integer conversion",ControllerScreenshotImageResize.resize(mask,to:.init(width:CGFloat.nan,height:CGFloat.infinity))==nil)
        check("screenshot error keeps its stable case spelling",String(describing:ControllerScreenshotCaptureError.screenCaptureFailed)=="screenCaptureFailed")
        let passed=checks.allSatisfy {$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,
            "actual_native_SCStreamConfiguration_setters_and_generated_image_resize":true,
            "actual_SCShareableContent_or_SCScreenshotManager_capture":false,
            "actual_SkyLight_capture_input_focus_or_preferences":false,
            "full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Screenshot native configuration/resize: \(checks.filter {$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
