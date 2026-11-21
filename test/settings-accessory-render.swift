import AppKit
import SwiftUI

@main struct RenderChecks {
    @MainActor static func main() throws {
        let app=NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var rows=[[String:Any]](),artifacts=[[String:Any]]()
        func check(_ value:Bool,_ label:String) { rows.append(["name":label,"passed":value]);precondition(value,label);print("PASS \(label)");fflush(stdout) }
        let context=CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.15,green:0.35,blue:0.85,alpha:1));context.fill(CGRect(x:0,y:0,width:32,height:32))
        let icon=NSImage(cgImage:context.makeImage()!,size:NSSize(width:32,height:32))
        let hint=SettingsAccessoryAssets.hintArrow!
        var callbacks=0
        let view=SettingsAccessoryForeground(applicationName:"Agent",destination:.privacyAccessibility,hintArrow:hint,showsHintArrow:true,onBack:{callbacks += 1},
            row:{SettingsAccessoryApplicationRow(applicationName:"Agent",icon:icon)})
        let window=NSWindow(contentRect:CGRect(x:12.25,y:34.5,width:531,height:110),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer { window.close() }
        let host=NSHostingView(rootView:view)
        window.contentView=host
        check(!window.isVisible && !window.isKeyWindow && !window.isMainWindow,"owned render fixture creates a hidden non-key window only")
        check(SettingsAccessoryForegroundCapture.capture(window:window,controllerView:host,hostingView:nil,content:view)==nil,"missing hosting prerequisite returns no capture")
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            app.appearance=NSAppearance(named:appearance)
            window.appearance=NSAppearance(named:appearance)
            let capture=SettingsAccessoryForegroundCapture.capture(window:window,controllerView:host,hostingView:host,content:view)!
            check(capture.frameOnScreen == window.convertToScreen(host.convert(host.bounds,to:nil)).integral && capture.cornerRadius==14,"\(name) foreground capture uses integral content screen frame and radius 14")
            check(capture.artwork?.size == CGSize(width:531,height:110),"\(name) foreground has a 531 by 110 point size")
            let image=capture.artwork!,bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
            check(bitmap.pixelsWide==Int(531*window.backingScaleFactor) && bitmap.pixelsHigh==Int(110*window.backingScaleFactor),"\(name) rendering uses the actual hidden window backing scale")
            let path=out.appendingPathComponent(name+".png");try bitmap.representation(using:.png,properties:[:])!.write(to:path)
            let preview=ImageRenderer(content:view.background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,name=="dark" ? .dark : .light))
            preview.scale=window.backingScaleFactor
            let previewBitmap=NSBitmapImageRep(data:preview.nsImage!.tiffRepresentation!)!
            try previewBitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(name+"-preview.png"))
            let empty=bitmap.colorAt(x:Int(5*window.backingScaleFactor),y:Int(5*window.backingScaleFactor))!.usingColorSpace(.deviceRGB)!
            check(empty.alphaComponent==0,"\(name) foreground excludes full-window material and leaves its outside transparent")
            artifacts.append(["appearance":name,"path":path.path,"points":[image.size.width,image.size.height],"pixels":[bitmap.pixelsWide,bitmap.pixelsHigh],"backingScale":window.backingScaleFactor])
        }
        let emptyCapture=SettingsAccessoryForegroundCapture.capture(window:window,controllerView:host,hostingView:host,content:EmptyView())!
        check(emptyCapture.artwork==nil && emptyCapture.cornerRadius==14,"a nil ImageRenderer image still returns the frame/radius capture")
        check(callbacks==0 && !window.isVisible,"rendering never invokes the back action or shows the fixture")
        let result:[String:Any]=["passed":true,"cases":rows.count,"results":rows,"artifacts":artifacts,"ownedHiddenWindowAndRenderingExecuted":true,"windowOrderedFrontOrInputOrScreenCaptureExecuted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("result.json"))
    }
}
