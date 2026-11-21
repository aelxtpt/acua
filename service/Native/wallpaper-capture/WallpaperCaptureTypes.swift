import Foundation
import CoreGraphics
import AppKit

enum WallpaperDisplayIdentifier {
    static func value(in dictionary:[NSDeviceDescriptionKey:Any])->UInt32? {
        (dictionary[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum WallpaperCaptureResolution:Sendable,Equatable {
    case scaled(Double)
    case nativeScale
    func scale(backing:Double)->Double {switch self{case .scaled(let value):return value;case .nativeScale:return backing}}
}
struct WallpaperCaptureRequest:Sendable,Equatable {
    let displayID:UInt32
    let size:CGSize
    let scale:Double
    var pixelWidth:Int {Int(size.width*scale)}
    var pixelHeight:Int {Int(size.height*scale)}
}
struct WallpaperCaptureWindow:Sendable {
    let id:UInt32,bundleIdentifier:String?,title:String?,frame:CGRect
}
enum WallpaperCaptureSelection {
    static func lastOwnedIndex(windowIDs:[UInt32],ownedNumbers:Set<NSNumber>)->Int? {
        windowIDs.indices.reversed().first{ownedNumbers.contains(NSNumber(value:windowIDs[$0]))}
    }
    static func wallpaperIndex(windows:[WallpaperCaptureWindow],displayFrame:CGRect,ownedNumbers:Set<NSNumber>)->Int? {
        let matches=windows.indices.filter {index in
            let w=windows[index]
            return (w.bundleIdentifier=="com.apple.dock" || w.bundleIdentifier=="com.apple.WindowManager") &&
                w.title?.hasPrefix("Wallpaper")==true && w.frame.equalTo(displayFrame)
        }
        let ids=matches.map{windows[$0].id}
        if let index=lastOwnedIndex(windowIDs:ids,ownedNumbers:ownedNumbers){return matches[index]}
        return matches.last
    }
}
enum WallpaperCaptureError:Error,Equatable {
    case missingDisplayID
    case displayNotFound(UInt32)
    case wallpaperWindowNotFound(UInt32)
}
protocol WallpaperCaptureEvents:AnyObject,Sendable {var stream:AsyncStream<Void>{get}}
enum WallpaperCaptureDiagnostic:Sendable {case preparation,capture,preparationCompleted,captureCompleted,missingSubscription,waitingForUnlock,filesystem}

@MainActor protocol WallpaperCaptureBackend {
    associatedtype Screen
    associatedtype Image:Sendable
    func displayID(for screen:Screen)->UInt32?
    func request(for screen:Screen,id:UInt32,resolution:WallpaperCaptureResolution)->WallpaperCaptureRequest
    func overrideEnabled()->Bool
    func overrideImage()->Image?
    func makeEvents()->any WallpaperCaptureEvents
    func screenLocked()->Bool?
    func waitUntilUnlocked() async -> Bool
    func capture(_ request:WallpaperCaptureRequest) async throws -> Image
    func report(_ diagnostic:WallpaperCaptureDiagnostic,displayID:UInt32,error:(any Error)?)
}
