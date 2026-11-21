import AppKit
import ScreenCaptureKit
import ObjectiveC
import SwiftUI

@MainActor final class WallpaperNativeCaptureBackend:WallpaperCaptureBackend {
    typealias Screen=NSScreen
    typealias Image=CGImage
    private let overrideFlag:()->Bool
    private let diagnostic:(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void
    init(overrideEnabled:@escaping ()->Bool,diagnostic:@escaping(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void={_,_,_ in}) {
        overrideFlag=overrideEnabled;self.diagnostic=diagnostic
    }
    func displayID(for screen:NSScreen)->UInt32? {
        WallpaperDisplayIdentifier.value(in:screen.deviceDescription)
    }
    func request(for screen:NSScreen,id:UInt32,resolution:WallpaperCaptureResolution)->WallpaperCaptureRequest {
        let size=screen.frame.size
        let scale:Double
        switch resolution{case .scaled(let value):scale=value;case .nativeScale:scale=screen.backingScaleFactor}
        return .init(displayID:id,size:size,scale:scale)
    }
    func overrideEnabled()->Bool{overrideFlag()}
    func overrideImage()->CGImage? {
        let path=("~/Pictures/AcuaWallpaper.jpg" as NSString).expandingTildeInPath
        guard let image=NSImage(contentsOf:URL(fileURLWithPath:path)) else{return nil}
        var rect=CGRect(origin:.zero,size:image.size)
        return image.cgImage(forProposedRect:&rect,context:nil,hints:nil)
    }
    func makeEvents()->any WallpaperCaptureEvents{WallpaperNativeEvents{[self] in diagnostic($0,$1,$2)}}
    func screenLocked()->Bool?{Self.currentLockState()}
    nonisolated static func currentLockState()->Bool? {
        guard let dictionary=CGSessionCopyCurrentDictionary() as? [String:Any] else{return nil}
        return dictionary["CGSSessionScreenIsLocked"] as? Bool
    }
    func waitUntilUnlocked() async -> Bool {
        await WallpaperScreenUnlockWaiter.wait(.init(locked:Self.currentLockState,nextNotification:{name in
            let iterator=DistributedNotificationCenter.default().notifications(named:.init(name)).makeAsyncIterator()
            return await iterator.next() != nil
        },sleep:{try await ContinuousClock().sleep(for:$0)}))
    }
    func capture(_ request:WallpaperCaptureRequest) async throws -> CGImage {
        try await WallpaperNativeCaptureWorker.capture(request)
    }
    func report(_ diagnostic:WallpaperCaptureDiagnostic,displayID:UInt32,error:(any Error)?){self.diagnostic(diagnostic,displayID,error)}
}

enum WallpaperNativeCaptureWorker {
    nonisolated static func capture(_ request:WallpaperCaptureRequest) async throws -> CGImage {
        let content:SCShareableContent
        if #available(macOS 14.4,*){content=try await SCShareableContent.currentProcess}
        else{content=try await SCShareableContent.current}
        try Task.checkCancellation()
        guard let display=content.displays.first(where:{$0.displayID==request.displayID}) else{
            throw WallpaperCaptureError.displayNotFound(request.displayID)
        }
        let windows=content.windows
        let descriptions=windows.map{WallpaperCaptureWindow(id:$0.windowID,bundleIdentifier:$0.owningApplication?.bundleIdentifier,title:$0.title,frame:$0.frame)}
        // The worker queries the application's window numbers, then prefers
        // the last matching wallpaper window owned by this process.
        let owned=ownedWindowNumbers()
        guard let index=WallpaperCaptureSelection.wallpaperIndex(windows:descriptions,displayFrame:display.frame,ownedNumbers:owned) else{
            throw WallpaperCaptureError.wallpaperWindowNotFound(request.displayID)
        }
        let filter=SCContentFilter(desktopIndependentWindow:windows[index])
        let configuration=configuration(for:request)
        // There is no second cancellation check after the native screenshot.
        return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)
    }
    nonisolated static func configuration(for request:WallpaperCaptureRequest)->SCStreamConfiguration {
        let configuration=SCStreamConfiguration()
        configuration.showsCursor=false;configuration.pixelFormat=1111970369
        configuration.width=request.pixelWidth;configuration.height=request.pixelHeight
        return configuration
    }
    nonisolated private static func ownedWindowNumbers()->Set<NSNumber> {
        // The worker makes this ObjC class call on its background
        // executor. Preserve that boundary instead of adding a MainActor hop.
        let cls:AnyClass=objc_lookUpClass("NSWindow")!
        let selector=NSSelectorFromString("windowNumbersWithOptions:")
        let method=class_getClassMethod(cls,selector)!
        let invoke=unsafeBitCast(method_getImplementation(method),to:(@convention(c)(AnyClass,Selector,UInt)->Unmanaged<NSArray>?).self)
        guard let numbers=invoke(cls,selector,1)?.takeUnretainedValue() as? [NSNumber] else{return []}
        return Set(numbers)
    }
}

@MainActor final class LockScreenNativeWallpaperProvider:LockScreenWallpaperProviding {
    let provider:WallpaperCaptureProvider<WallpaperNativeCaptureBackend>
    init(resolution:WallpaperCaptureResolution = .nativeScale,overrideEnabled:@escaping ()->Bool,
         diagnostic:@escaping(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void={_,_,_ in}) {
        provider = .init(backend:.init(overrideEnabled:overrideEnabled,diagnostic:diagnostic),resolution:resolution)
    }
    func cachedWallpaper(for screen:NSScreen)->CGImage?{provider.cachedWallpaper(for:screen)}
    func monitorWallpaper(for screen:NSScreen)throws->AsyncThrowingStream<CGImage,Error>{try provider.monitorWallpaper(for:screen)}
    func prepareWallpaper(for screen:NSScreen){provider.prepareWallpaper(for:screen)}
    func cachedWallpaperImage(for screen:NSScreen?)->SwiftUI.Image? {
        guard let image=provider.cachedWallpaper(for:screen) else{return nil}
        return WallpaperNativeImageBridge.swiftUI(image)
    }
}
