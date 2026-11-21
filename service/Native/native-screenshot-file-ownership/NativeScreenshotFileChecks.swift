import AppKit
import Foundation
import ImageIO
import System

private final class NativeScreenshotFailureLog:@unchecked Sendable {
    private let lock=NSLock();private var countValue=0
    func record(){lock.withLock{countValue+=1}}
    var count:Int{lock.withLock{countValue}}
}
@MainActor enum NativeScreenshotFileChecks {
    static func run(output:URL)async throws->Int32 {
        let parent=output.deletingLastPathComponent()
        let core=try await ScreenshotFileCoreChecks.run(output:parent.appendingPathComponent("core-result.json"),directory:parent.appendingPathComponent("owned-core"))
        guard core==0 else{return core}
        let directory=parent.appendingPathComponent("owned-adapter")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ passed:Bool){checks.append(["name":name,"passed":passed]);if !passed{print("FAIL: "+name)}}
        let image=ScreenshotFileCoreChecks.image(),date=Date(timeIntervalSince1970:0),log=NativeScreenshotFailureLog()
        let file=try NativeAppSnapshotImage.writeFile(image,appName:"Owned é",directory:directory,date:date,encoding:.png)
        let geometry=ScreenshotGeometry(windowID:771,ownerPID:getpid(),screenFrame:CGRect(x:0,y:0,width:2,height:2),pixelWidth:2,pixelHeight:2,includedWindowIDs:[771])
        let captured=Capture.Captured(path:file.url,width:2,height:2,geometry:geometry,nativePath:file.path)
        check("native writer and capture retain the written FilePath independently from URL",captured.nativePath==file.path && file.path != FilePath(file.url.path(percentEncoded:false)))
        var owner:ControllerTemporaryImage? = .adoptingNative(captured.path,filePath:captured.nativePath,log:{_,_ in log.record()})
        let rawIdentity=ControllerTemporaryImage(adopting:file.url,identity:file.path,cleanup:{_ in},failed:{_ in})
        let URLIdentity=ControllerTemporaryImage(adopting:file.url,cleanup:{_ in},failed:{_ in})
        check("native image owner uses the written FilePath identity",owner==rawIdentity && owner != URLIdentity)
        var attachment=owner;owner=nil
        check("native artifact remains until last attachment releases",attachment != nil && FileManager.default.fileExists(atPath:file.path.string))
        attachment=nil
        check("native final ARC release removes the written path and drops legacy registry",!FileManager.default.fileExists(atPath:file.path.string) && log.count==0 && !NativeAppSnapshotImage.removeIfOwned(file.url))
        let missing=try NativeAppSnapshotImage.writeFile(image,appName:"Owned removed",directory:directory,date:date,encoding:.png)
        var missingOwner:ControllerTemporaryImage? = .adoptingNative(missing.url,filePath:missing.path,log:{_,_ in log.record()})
        try FileManager.default.removeItem(atPath:missing.path.string)
        withExtendedLifetime(missingOwner){};missingOwner=nil
        check("failed native deletion reports once and still drops legacy registry",log.count==1 && !NativeAppSnapshotImage.removeIfOwned(missing.url))
        let legacy=try NativeAppSnapshotImage.write(image,appName:"Owned URL adapter",directory:directory,date:date,encoding:.jpeg(0.8))
        check("URL compatibility adapter retains legacy removal support",CGImageSourceCreateWithURL(legacy as CFURL,nil) != nil && NativeAppSnapshotImage.removeIfOwned(legacy) && !FileManager.default.fileExists(atPath:legacy.path))
        for quality in [-Double.infinity,-1,0,Double.nan,Double.infinity,2] {
            check("configuration invalid JPEG quality remains absent \(quality)",NativeAppSnapshotImage.encoding(useJPEG:true,quality:quality).properties==nil)
        }
        check("valid configuration JPEG quality is preserved",(NativeAppSnapshotImage.encoding(useJPEG:true,quality:0.8).properties as? [String:Any])?[kCGImageDestinationLossyCompressionQuality as String] as? Double == 0.8)
        let failure=ControllerImageDestinationError.failedToCreateImageDestination
        let mapped=ControllerNativeMappedError.classify(failure),xpc=ComputerUseXPC.requestError(failure)
        check("image destination creation failure keeps the generic wire value",mapped.code == .unknownError && mapped.payload=="failedToCreateImageDestination" && mapped.socketDescription=="Computer Use server error -10005: failedToCreateImageDestination" && xpc.code == -10005 && xpc.localizedDescription=="failedToCreateImageDestination")
        let refetch=try NativeRefetchBindingChecks.run(output:parent.appendingPathComponent("refetch-result.json"))
        check("native refetch and generated-image ownership regression passes",refetch==0)
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,"actual_native_ImageIO_file_adapter_and_capture_path_field_executed":true,"actual_screen_capture_input_focus_or_general_clipboard":false,"full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native screenshot file adapter: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
