import Foundation
import ImageIO
import System
import UniformTypeIdentifiers

private final class ScreenshotFileLog:@unchecked Sendable {
    private let lock=NSLock();private var values:[String]=[]
    func add(_ value:String){lock.withLock{values.append(value)}}
    var all:[String]{lock.withLock{values}}
}
private final class ScreenshotPartialSink:@unchecked Sendable {
    let url:URL,log:ScreenshotFileLog
    private let lock=NSLock();private var remaining=24
    init(url:URL,log:ScreenshotFileLog){self.url=url;self.log=log}
    func put(_ bytes:UnsafeRawPointer,_ count:Int)->Int {
        lock.withLock {
            let written=min(remaining,count);remaining-=written
            do {
                if written>0{
                    if !FileManager.default.fileExists(atPath:url.path){_ = FileManager.default.createFile(atPath:url.path,contents:Data())}
                    let handle=try FileHandle(forWritingTo:url)
                    try handle.seekToEnd();try handle.write(contentsOf:Data(bytes:bytes,count:written));try handle.close()
                }
                log.add("write:\(written)/\(count)");return written
            }catch{log.add("io-error");return 0}
        }
    }
    deinit{log.add("released")}
}

@MainActor enum ScreenshotFileCoreChecks {
    static func image()->CGImage {
        let context=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.6,alpha:1));context.fill(CGRect(x:0,y:0,width:2,height:2))
        return context.makeImage()!
    }
    static func run(output:URL,directory:URL)async throws->Int32 {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ passed:Bool){checks.append(["name":name,"passed":passed]);if !passed{print("FAIL: "+name)}}
        let suffix=" D",ext=".png"
        let cases:[(String,String,String,String,String)]=[
            ("slash replacement only","A/B",suffix,ext,"A:B D.png"),
            ("embedded NUL is not rewritten by filename helper","A\0B",suffix,ext,"A\0B D.png"),
            ("exact UTF16 budget",String(repeating:"x",count:243),suffix,ext,String(repeating:"x",count:243)+" D.png"),
            ("over budget replaces final UTF16 unit with ellipsis",String(repeating:"x",count:244),suffix,ext,String(repeating:"x",count:242)+"… D.png"),
            ("combining sequences are cut in UTF16 units",String(repeating:"e\u{301}",count:200),suffix,ext,String(repeating:"e\u{301}",count:121)+"… D.png"),
            ("no invented UTF8 filename clamp",String(repeating:"é",count:200),suffix,ext,String(repeating:"é",count:200)+" D.png"),
            ("UTF16 repair after surrogate truncation","😀Z",String(repeating:"s",count:243),ext,"\u{fffd}…"+String(repeating:"s",count:243)+ext),
            ("no remaining suffix budget returns255 source units",String(repeating:"w",count:300),String(repeating:"s",count:250),ext,String(repeating:"w",count:255))]
        for (name,base,suffix,ext,want) in cases{check(name,ControllerScreenshotFilename.compose(base:base,suffix:suffix,extension:ext)==want)}
        let date=Date(timeIntervalSince1970:0)
        let appName=ControllerScreenshotFilename.make(appName:"Owned/App",date:date,encoding:.png)
        check("application name receives Screenshot suffix and native extension",appName.hasPrefix("Owned:App Screenshot ") && appName.hasSuffix(".png"))
        check("nil application name uses Screenshot",ControllerScreenshotFilename.make(appName:nil,date:date,encoding:.png).hasPrefix("Screenshot "))
        check("present empty application name is preserved",ControllerScreenshotFilename.make(appName:"",date:date,encoding:.jpeg(nil)).hasPrefix(" Screenshot "))
        for (name,quality,want) in [("negative",CGFloat(-0.2),CGFloat(0)),("negative zero",CGFloat(-0.0),CGFloat(0)),("zero",CGFloat(0),CGFloat(0)),("middle",CGFloat(0.8),CGFloat(0.8)),("one",CGFloat(1),CGFloat(1)),("above one",CGFloat(2),CGFloat(1)),("positive infinity",CGFloat.infinity,CGFloat(1)),("negative infinity",-CGFloat.infinity,CGFloat(0))] {
            let property=ControllerScreenshotEncoding.jpeg(quality).properties as? [String:Any]
            let actual=(property?[kCGImageDestinationLossyCompressionQuality as String] as? NSNumber)?.doubleValue
            check("native JPEG quality clamp "+name,actual==Double(want) && (want != 0 || actual?.sign == .plus))
        }
        let nan=ControllerScreenshotEncoding.jpeg(.nan).properties as? [String:Any]
        check("raw present NaN quality is retained by ordered clamps",(nan?[kCGImageDestinationLossyCompressionQuality as String] as? NSNumber)?.doubleValue.isNaN==true)
        check("absent JPEG quality and PNG pass nil properties",ControllerScreenshotEncoding.jpeg(nil).properties==nil && ControllerScreenshotEncoding.png.properties==nil)
        let pathLog=ScreenshotFileLog(),base=FilePath(directory.path(percentEncoded:false))
        let selected=ControllerScreenshotPaths.unique(filename:"owned.png",directory:base,environment:.init(exists:{path in pathLog.add("exists:"+path);return path==base.appending("owned.png").string || path==base.appending("1/owned.png").string},ensureDirectory:{path in pathLog.add("mkdir:"+path.string)}))
        check("collisions choose sibling numbered directories and prepare only chosen one",selected==base.appending("2/owned.png") && pathLog.all==["exists:"+base.appending("owned.png").string,"exists:"+base.appending("1/owned.png").string,"exists:"+base.appending("2/owned.png").string,"mkdir:"+base.appending("2").string])
        let freshLog=ScreenshotFileLog()
        let fresh=ControllerScreenshotPaths.unique(filename:"fresh.png",directory:base,environment:.init(exists:{_ in false},ensureDirectory:{_ in freshLog.add("unexpected")}))
        check("collision-free explicit base is not created by uniquePath",fresh==base.appending("fresh.png") && freshLog.all.isEmpty)
        let failed=ControllerScreenshotPaths.unique(filename:"failure.png",directory:base,environment:.init(exists:{$0==base.appending("failure.png").string},ensureDirectory:{_ in throw CocoaError(.fileWriteNoPermission)}))
        check("collision directory preparation error is swallowed",failed==base.appending("1/failure.png"))
        let blocker=directory.appendingPathComponent("owned-directory-file")
        try Data([1]).write(to:blocker)
        try ControllerScreenshotPaths.ensureDirectory(FilePath(blocker.path(percentEncoded:false)))
        var isDirectory:ObjCBool=false
        check("regular file at selected directory path is replaced",FileManager.default.fileExists(atPath:blocker.path,isDirectory:&isDirectory) && isDirectory.boolValue)
        let image=image(),register=ScreenshotFileLog()
        for (name,encoding) in [("PNG",ControllerScreenshotEncoding.png),("JPEG",.jpeg(0.8))] {
            let url=try ControllerScreenshotFileWriter<CGImageDestination>(environment:.init(paths:.native,create:{ControllerScreenshotImageIO.create($0,$1)},addAndFinalize:{ControllerScreenshotImageIO.addAndFinalize($0,$1,$2)},register:{register.add($0.path)})).write(image,appName:"Owned "+name,directory:directory,date:date,encoding:encoding)
            let source=CGImageSourceCreateWithURL(url as CFURL,nil)
            let decoded=source.flatMap{CGImageSourceCreateImageAtIndex($0,0,nil)}
            let type=source.flatMap{CGImageSourceGetType($0)}.map{$0 as String}
            check("actual direct URL ImageIO encoding "+name,decoded?.width==2 && decoded?.height==2 && type==encoding.type.identifier && register.all.contains(url.path))
            var owned:ControllerTemporaryImage? = .init(adopting:url,cleanup:{try FileManager.default.removeItem(atPath:$0.path(percentEncoded:false))},failed:{_ in register.add("cleanup-error")})
            withExtendedLifetime(owned){}
            owned=nil
            check("generated "+name+" file is deleted on final ARC release",!FileManager.default.fileExists(atPath:url.path) && !register.all.contains("cleanup-error"))
        }
        let collisionName=ControllerScreenshotFilename.make(appName:"Collision",date:date,encoding:.png)
        try Data([7]).write(to:directory.appendingPathComponent(collisionName))
        let collision=try ControllerScreenshotFileWriter<CGImageDestination>(environment:.init(paths:.native,create:{ControllerScreenshotImageIO.create($0,$1)},addAndFinalize:{ControllerScreenshotImageIO.addAndFinalize($0,$1,$2)},register:{_ in})).write(image,appName:"Collision",directory:directory,date:date,encoding:.png)
        check("real collision creates numbered parent before URL encoding",collision.deletingLastPathComponent().lastPathComponent=="1" && CGImageSourceCreateWithURL(collision as CFURL,nil) != nil)
        struct Destination:Sendable{let url:URL}
        let partialLog=ScreenshotFileLog()
        let partial=try ControllerScreenshotFileWriter<Destination>(environment:.init(paths:.native,create:{url,_ in .init(url:url)},addAndFinalize:{destination,_,_ in
            do{try Data([1,2,3]).write(to:destination.url);partialLog.add("finalize:false")}catch{partialLog.add("write-error")}
            return false
        },register:{_ in partialLog.add("registered")})).write(image,appName:"Owned partial",directory:directory,date:date,encoding:.png)
        let partialData=try Data(contentsOf:partial)
        check("false finalize still returns and registers selected file",partialLog.all==["finalize:false","registered"] && partialData==Data([1,2,3]))
        var owner:ControllerTemporaryImage? = .init(adopting:partial,cleanup:{try FileManager.default.removeItem(at:$0)},failed:{_ in partialLog.add("cleanup-error")})
        var attachment=owner;owner=nil
        check("partial file survives while attachment holds owner",attachment != nil && FileManager.default.fileExists(atPath:partial.path))
        attachment=nil
        check("partial file deleted when final attachment releases",!FileManager.default.fileExists(atPath:partial.path) && !partialLog.all.contains("cleanup-error"))
        let failedLog=ScreenshotFileLog()
        do {
            _ = try ControllerScreenshotFileWriter<Destination>(environment:.init(paths:.native,create:{_,_ in nil},addAndFinalize:{_,_,_ in failedLog.add("unexpected-finalize");return true},register:{_ in failedLog.add("unexpected-register")})).write(image,appName:"Owned creation failure",directory:directory,date:date,encoding:.png)
            check("creation failure returns its error value before finalization",false)
        }catch{check("creation failure returns its error value before finalization",String(describing:error)=="failedToCreateImageDestination" && failedLog.all.isEmpty)}
        let sinkLog=ScreenshotFileLog(),finalizeLog=ScreenshotFileLog()
        let short=try ControllerScreenshotFileWriter<CGImageDestination>(environment:.init(paths:.native,create:{url,encoding in
            let sink=ScreenshotPartialSink(url:url,log:sinkLog)
            let pointer=Unmanaged.passRetained(sink).toOpaque()
            var callbacks=CGDataConsumerCallbacks(putBytes:{info,buffer,count in
                guard let info else{return 0}
                return Unmanaged<ScreenshotPartialSink>.fromOpaque(info).takeUnretainedValue().put(buffer,count)
            },releaseConsumer:{info in if let info{Unmanaged<ScreenshotPartialSink>.fromOpaque(info).release()}})
            guard let consumer=CGDataConsumer(info:pointer,cbks:&callbacks) else{Unmanaged<ScreenshotPartialSink>.fromOpaque(pointer).release();return nil}
            return CGImageDestinationCreateWithDataConsumer(consumer,encoding.type.identifier as CFString,1,nil)
        },addAndFinalize:{destination,image,encoding in
            let result=ControllerScreenshotImageIO.addAndFinalize(destination,image,encoding);finalizeLog.add(String(result));return result
        },register:{_ in finalizeLog.add("registered")})).write(image,appName:"Owned native short write",directory:directory,date:date,encoding:.png)
        check("actual ImageIO short consumer returns false but file is adopted",finalizeLog.all==["false","registered"] && FileManager.default.fileExists(atPath:short.path) && !sinkLog.all.contains("io-error"))
        check("actual native data consumer is released",sinkLog.all.contains("released"))
        var shortOwner:ControllerTemporaryImage? = .init(adopting:short,cleanup:{try FileManager.default.removeItem(at:$0)},failed:{_ in sinkLog.add("cleanup-error")})
        withExtendedLifetime(shortOwner){};shortOwner=nil
        check("actual native short-write artifact is removed by ARC",!FileManager.default.fileExists(atPath:short.path) && !sinkLog.all.contains("cleanup-error"))
        let cancellation=Task { ()throws->URL in
            withUnsafeCurrentTask{$0?.cancel()}
            return try ControllerScreenshotFileWriter<Destination>(environment:.init(paths:.native,create:{url,_ in .init(url:url)},addAndFinalize:{_,_,_ in true},register:{_ in})).write(image,appName:"Owned cancelled",directory:directory,date:date,encoding:.png)
        }
        do{_ = try await cancellation.value;check("writer does not add a cancellation check",true)}catch{check("writer does not add a cancellation check",false)}
        let identities:[(String,String,Bool)]=[("a//b","a/b",true),("a/","a",true),("a/./b","a/b",false),("é","e\u{301}",false)]
        for (a,b,want) in identities {
            let lhs=ControllerTemporaryImage(adopting:URL(fileURLWithPath:directory.path+"/"+a),identity:FilePath(directory.path+"/"+a),cleanup:{_ in},failed:{_ in})
            let rhs=ControllerTemporaryImage(adopting:URL(fileURLWithPath:directory.path+"/"+b),identity:FilePath(directory.path+"/"+b),cleanup:{_ in},failed:{_ in})
            check("native FilePath identity "+a+" vs "+b,(lhs==rhs)==want && Set([lhs,rhs]).count==(want ? 1:2))
        }
        let spelling=try ControllerScreenshotFileWriter<Destination>(environment:.init(paths:.native,create:{url,_ in .init(url:url)},addAndFinalize:{_,_,_ in true},register:{_ in})).writeFile(image,appName:"Owned é",directory:directory,date:date,encoding:.png)
        check("written file retains native Unicode spelling independently of URL",spelling.path.string.contains("é") && spelling.path != FilePath(spelling.url.path(percentEncoded:false)))
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        let report:[String:Any]=["passed":passed,"checks":checks,"generated_image_dimensions":[2,2],"actual_ImageIO_URL_encoding":true,"actual_ImageIO_short_consumer_failure_and_ARC_cleanup":true,"actual_screen_capture_input_or_focus":false,"full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Screenshot file core: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
