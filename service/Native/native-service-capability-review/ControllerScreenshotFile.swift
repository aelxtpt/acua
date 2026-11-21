import Foundation
import ImageIO
import OSLog
import System
import UniformTypeIdentifiers

enum ControllerScreenshotEncoding:Sendable {
    case jpeg(CGFloat?)
    case png
    var type:UTType {switch self{case .jpeg:return .jpeg;case .png:return .png}}
    var properties:CFDictionary? {
        guard case .jpeg(let quality?)=self else{return nil}
        // Ordered floating comparisons: a present NaN is retained.
        let lower=quality <= 0 ? CGFloat(0):quality
        let clamped=lower > 1 ? CGFloat(1):lower
        return [kCGImageDestinationLossyCompressionQuality as String:clamped] as CFDictionary
    }
}

enum ControllerScreenshotFilename {
    private static let lock=NSLock()
    private static let formatters:(DateFormatter,DateFormatter)={
        let date=DateFormatter();date.dateFormat="yyyy-MM-dd"
        let time=DateFormatter();time.dateFormat="h.mm.ss a"
        return (date,time)
    }()
    static func make(appName:String?,date:Date,encoding:ControllerScreenshotEncoding)->String {
        let suffix=lock.withLock{" \(formatters.0.string(from:date)) at \(formatters.1.string(from:date))"}
        let ext=String((" " as NSString).appendingPathExtension(for:encoding.type).dropFirst())
        return compose(base:appName.map{$0+" Screenshot"} ?? "Screenshot",suffix:suffix,extension:ext)
    }
    static func compose(base:String,suffix:String,extension ext:String)->String {
        let source=Array(base.replacingOccurrences(of:"/",with:":").utf16)
        let budget=249-suffix.utf16.count-ext.utf16.count
        guard budget>=1 else{return String(decoding:source.prefix(255),as:UTF16.self)}
        var units=Array(source.prefix(budget))
        if source.count>budget {units.removeLast();units.append(0x2026)}
        units.append(contentsOf:suffix.utf16);units.append(contentsOf:ext.utf16)
        return String(decoding:units,as:UTF16.self)
    }
}

enum ControllerScreenshotPaths {
    struct Environment:Sendable {
        let exists:@Sendable (String)->Bool
        let ensureDirectory:@Sendable (FilePath)throws->Void
        static var native:Self {.init(exists:{FileManager.default.fileExists(atPath:$0)},ensureDirectory:{try ControllerScreenshotPaths.ensureDirectory($0)})}
    }
    static func unique(filename:String,directory:FilePath,environment:Environment = .native)->FilePath {
        var path=directory.appending(filename),parent:FilePath?,collision=0
        while environment.exists(path.string) {
            collision+=1
            let next=directory.appending(String(collision))
            path=next.appending(filename);parent=next
        }
        // Create only the selected numbered parent, ignoring failure.
        if let parent{try? environment.ensureDirectory(parent)}
        return path
    }
    static func ensureDirectory(_ path:FilePath)throws {
        let manager=FileManager.default
        var directory:ObjCBool=false
        if manager.fileExists(atPath:path.string,isDirectory:&directory) {
            if directory.boolValue{return}
            try manager.removeItem(atPath:path.string)
        }
        try manager.createDirectory(atPath:path.string,withIntermediateDirectories:true,attributes:nil)
    }
}

enum ControllerImageDestinationError:Error {case failedToCreateImageDestination}

struct ControllerScreenshotWrittenFile:Sendable {let path:FilePath;let url:URL}

struct ControllerScreenshotFileWriter<Destination>:Sendable {
    struct Environment:Sendable {
        let paths:ControllerScreenshotPaths.Environment
        let create:@Sendable (URL,ControllerScreenshotEncoding)->Destination?
        let addAndFinalize:@Sendable (Destination,CGImage,ControllerScreenshotEncoding)throws->Bool
        let register:@Sendable (URL)->Void
    }
    let environment:Environment
    func write(_ image:CGImage,appName:String?,directory:URL,date:Date,encoding:ControllerScreenshotEncoding)throws->URL {
        try writeFile(image,appName:appName,directory:directory,date:date,encoding:encoding).url
    }
    func writeFile(_ image:CGImage,appName:String?,directory:URL,date:Date,encoding:ControllerScreenshotEncoding)throws->ControllerScreenshotWrittenFile {
        let filename=ControllerScreenshotFilename.make(appName:appName,date:date,encoding:encoding)
        let path=ControllerScreenshotPaths.unique(filename:filename,directory:FilePath(directory.path(percentEncoded:false)),environment:environment.paths)
        let url=URL(filePath:path.string,directoryHint:.notDirectory)
        guard let destination=environment.create(url,encoding) else{throw ControllerImageDestinationError.failedToCreateImageDestination}
        // Ignore Finalize's Bool, then adopt the same selected path.
        _ = try environment.addAndFinalize(destination,image,encoding)
        environment.register(url)
        return .init(path:path,url:url)
    }
}

enum ControllerScreenshotImageIO {
    private static let signposter=OSSignposter(subsystem:"local.cua",category:"ScreenshotImplementation")
    static func create(_ url:URL,_ encoding:ControllerScreenshotEncoding)->CGImageDestination? {
        CGImageDestinationCreateWithURL(url as CFURL,encoding.type.identifier as CFString,1,nil)
    }
    static func addAndFinalize(_ destination:CGImageDestination,_ image:CGImage,_ encoding:ControllerScreenshotEncoding)->Bool {
        let interval=signposter.beginInterval("Finalize Destination")
        CGImageDestinationAddImage(destination,image,encoding.properties)
        let result=CGImageDestinationFinalize(destination)
        signposter.endInterval("Finalize Destination",interval)
        return result
    }
}
