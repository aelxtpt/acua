import AppKit
import Foundation
import ImageIO
import QuartzCore
import ScreenCaptureKit

@MainActor private final class LegacyCloseWitness: NSObject, NSWindowDelegate {
    var closed = false
    func windowWillClose(_ notification: Notification) { closed = true }
}

@MainActor final class NativeLegacyOffscreenChecks: NSObject, NSApplicationDelegate {
    let output: URL
    let directory: URL
    init(output: URL, directory: URL) { self.output=output;self.directory=directory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { exit(try await run()) }
            catch { FileHandle.standardError.write(Data(String(describing:error).utf8));exit(2) }
        }
    }
    private func sample(_ image: CGImage) -> [Int]? {
        guard let cropped=image.cropping(to:.init(x:image.width/2,y:image.height/2,width:1,height:1)),
              let context=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let data=context.data else { return nil }
        context.draw(cropped,in:.init(x:0,y:0,width:1,height:1))
        return (0..<4).map { Int(data.load(fromByteOffset:$0,as:UInt8.self)) }
    }
    private func run() async throws -> Int32 {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let foreground=NSWorkspace.shared.frontmostApplication?.processIdentifier
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ ok:Bool) { checks.append(["name":name,"passed":ok]) }
        let witness=LegacyCloseWitness()
        var window:NSWindow?=NSWindow(contentRect:.init(x:12,y:12,width:240,height:160),
            styleMask:[.titled,.miniaturizable],backing:.buffered,defer:false)
        window!.delegate=witness;window!.isReleasedWhenClosed=false;window!.ignoresMouseEvents=true
        window!.title="Owned legacy offscreen capture";window!.isOpaque=true
        let color=NSColor(srgbRed:0.2,green:0.4,blue:0.6,alpha:1)
        window!.backgroundColor=color;window!.contentView?.wantsLayer=true
        window!.contentView?.layer?.backgroundColor=color.cgColor
        window!.orderFront(nil);window!.displayIfNeeded();CATransaction.flush()
        let id=UInt32(window!.windowNumber)
        var errorText:String?,capturePath:URL?,dimensions:[Int]?,pixel:[Int]?,metadata:[String:Any]=[:]
        var actualLegacyCapture=false
        do {
            check("owned window has visible native identity",id>0 && window!.isVisible)
            check("screen recording already authorized without prompt",CGPreflightScreenCaptureAccess())
            guard CGPreflightScreenCaptureAccess() else { throw ControllerScreenshotCaptureError.screenCaptureFailed }
            try await Task.sleep(for:.milliseconds(50));window!.miniaturize(nil)
            try await Task.sleep(for:.milliseconds(800))
            check("owned window is really minimized",window!.isMiniaturized)
            var selected:SCWindow?
            for _ in 0..<100 {
                let content=try await SCShareableContent.current
                selected=content.windows.first { $0.windowID==id && $0.owningApplication?.processID==getpid() }
                if let selected,!selected.isOnScreen { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            guard let selected,!selected.isOnScreen,selected.owningApplication?.processID==getpid() else { throw ControllerScreenshotCaptureError.screenCaptureFailed }
            metadata=["id":id,"pid":selected.owningApplication!.processID,"isOnScreen":selected.isOnScreen,
                "frame":[selected.frame.minX,selected.frame.minY,selected.frame.width,selected.frame.height]]
            check("real SDK metadata binds minimized window to owned process",selected.windowID==id && !selected.isOnScreen && selected.owningApplication?.processID==getpid())
            check("minimized window absent from native on-screen list",!ControllerOnScreenWindowIDs.read().contains(id))
            let captured=try await Capture.captureAsync(pid:getpid(),directory:directory,
                matching:.init(frame:selected.frame,title:selected.title,windowID:id),additionalWindowIDs:[],
                nativeAppName:"Owned C153 legacy capture",nativePlan:nil)
            actualLegacyCapture=true;capturePath=captured.path;dimensions=[captured.width,captured.height]
            check("actual legacy capture writes nonempty dimensions",captured.width>0 && captured.height>0)
            check("native file path survives through compatibility result",captured.nativePath != nil)
            check("legacy capture writes only to explicit owned directory",captured.path.deletingLastPathComponent().standardizedFileURL==directory.standardizedFileURL)
            guard let source=CGImageSourceCreateWithURL(captured.path as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw ControllerScreenshotCaptureError.screenCaptureFailed }
            pixel=sample(image)
            check("written image decodes with reported dimensions",image.width==captured.width && image.height==captured.height)
            check("owned minimized pixels survive default capture and encoding",pixel.map { zip($0,[51,102,153,255]).allSatisfy { abs($0-$1)<26 } } ?? false)
            check("default legacy native settings write an actual JPEG",CGImageSourceGetType(source) as String? == "public.jpeg")
            check("capture does not restore or activate minimized window",window!.isMiniaturized && !NSApp.isActive && !window!.isKeyWindow)
            Capture.removeTemporaryImage(captured.path.path)
            check("explicit legacy cleanup removes registered native file",!FileManager.default.fileExists(atPath:captured.path.path))
            let foreign=directory.appendingPathComponent("unregistered-native-image.jpeg")
            try Data([1,2,3]).write(to:foreign)
            Capture.removeTemporaryImage(foreign.path)
            check("cleanup retains an unregistered file in the owned fixture directory",FileManager.default.fileExists(atPath:foreign.path))
            try FileManager.default.removeItem(at:foreign)
            let foreignLegacy=directory.appendingPathComponent("app-snapshot-\(UUID().uuidString).jpg")
            try Data([4,5,6]).write(to:foreignLegacy)
            Capture.removeTemporaryImage(foreignLegacy.path)
            check("legacy-shaped unregistered file outside default directory is retained",FileManager.default.fileExists(atPath:foreignLegacy.path))
            try FileManager.default.removeItem(at:foreignLegacy)
        } catch { errorText=String(describing:error) }
        if let capturePath,FileManager.default.fileExists(atPath:capturePath.path) { Capture.removeTemporaryImage(capturePath.path) }
        window?.close();window=nil
        check("owned window emits its close notification",witness.closed)
        check("foreground remains unchanged",foreground==NSWorkspace.shared.frontmostApplication?.processIdentifier && !NSApp.isActive)
        check("legacy offscreen capture completed without error",actualLegacyCapture && errorText==nil)
        let passed=checks.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any]=["passed":passed,"checks":checks,"check_count":checks.count,
            "error":errorText as Any? ?? NSNull(),"actual_legacy_offscreen_capture":actualLegacyCapture,
            "native_functions_or_pixels_intercepted":false,"owned_window_metadata":metadata,
            "dimensions":dimensions as Any? ?? NSNull(),"center_pixel":pixel as Any? ?? NSNull(),
            "physical_input_or_focus_executed":false,"actual_owned_window_capture":actualLegacyCapture,
            "default_screenshot_directory_exercised":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Actual legacy offscreen capture: \(checks.filter { $0["passed"] as? Bool==true }.count)/\(checks.count)")
        return passed ? 0:3
    }
}
