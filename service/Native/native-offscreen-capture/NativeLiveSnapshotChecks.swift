import AppKit
import ApplicationServices
import Foundation
import ImageIO

private enum LiveNativeBufferFailure: Error { case failed }
private final class LiveNativeBufferSink: @unchecked Sendable {
    private let lock=NSLock()
    private var recorded:[String]=[]
    private var optionsValue:ControllerScreenshotCaptureOptions?
    private var failed=false,paused=false
    private var continuation:CheckedContinuation<CGImage,Never>?
    let image:CGImage
    init(image:CGImage) {self.image=image}
    var trace:[String] {lock.withLock {recorded}}
    var options:ControllerScreenshotCaptureOptions? {lock.withLock {optionsValue}}
    var hasContinuation:Bool {lock.withLock {continuation != nil}}
    func failNext() {lock.withLock {failed=true}}
    func pauseNext() {lock.withLock {paused=true}}
    func capture(_ options:ControllerScreenshotCaptureOptions) async throws -> CGImage {
        let state=lock.withLock {recorded.append("buffer");optionsValue=options;return (failed,paused)}
        if state.0 {throw LiveNativeBufferFailure.failed}
        if state.1 {return await withCheckedContinuation {value in lock.withLock {continuation=value}}}
        return image
    }
    func release() {let value=lock.withLock {let value=continuation;continuation=nil;return value};value?.resume(returning:image)}
    func directory(_ directory:URL)->URL {lock.withLock {recorded.append("directory")};return directory}
}

private final class LiveSnapshotNotifications: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    func add() { lock.withLock { count+=1 } }
    var value:Int { lock.withLock { count } }
}
private enum LiveSnapshotFailure:Error { case fixtureNotReady, missingBundle, stageManagerRequiresSeparateTest, capturePermissionRequired, unexpectedFixtureWindow, missingScreenshot }

@MainActor enum NativeLiveSnapshotChecks {
    static func run(output:URL,fixture:URL,directory:URL) async throws -> Int32 {
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ value:Bool) {
            checks.append(["name":name,"passed":value]); if !value { print("FAIL: "+name) }
        }
        let foreground=NSWorkspace.shared.frontmostApplication?.processIdentifier
        let config=NSWorkspace.OpenConfiguration(); config.activates=false; config.createsNewApplicationInstance=true
        let target=try await NSWorkspace.shared.openApplication(at:fixture,configuration:config)
        var errorDescription:String?
        var firstCount=0,secondCount=0
        var nativeOwnerCreated=false,actualSnapshotExecuted=false
        var actualLiveImageCapture=false,actualFullNativeCapture=false,ownedFixtureWindowVerified=false
        weak var releasedOwner:ControllerNativeAppSnapshotBackend.Owner?
        do {
            for _ in 0..<100 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) {
                try await Task.sleep(for:.milliseconds(10))
            }
            guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path),!target.isTerminated else { throw LiveSnapshotFailure.fixtureNotReady }
            guard let bundle=target.bundleIdentifier else { throw LiveSnapshotFailure.missingBundle }
            // This diagnostic must not reveal or move another Stage Manager
            // window. The existing operation and its production branch remain intact.
            guard UserDefaults(suiteName:"com.apple.WindowManager")?.bool(forKey:"GloballyEnabled") != true else { throw LiveSnapshotFailure.stageManagerRequiresSeparateTest }
            let assembly=try ControllerNativeAppSnapshotBackend.Assembly.native(analytics:{_ in},orderingLog:{_ in},
                hideCursor:{_ in preconditionFailure("Inactive snapshot diagnostic must not create/hide a cursor")},log:{_,_ in})
            var controller:ControllerNativeAppController?=try .init(target:.init(bundleIdentifier:bundle,url:fixture),
                chatID:nil,mcpRuntime:2,isAXTreeDiffingEnabled:true,assembly:assembly)
            releasedOwner=controller!.owner; nativeOwnerCreated=true
            check("actual native owner resolves the running owned fixture",controller!.owner.pid==target.processIdentifier)
            check("native constructor seeds the fixture window registry",!controller!.owner.windows().isEmpty)
            check("native constructor remains inactive without focus or cursor",!controller!.owner.isActive && controller!.owner.focusEnforcer==nil && controller!.owner.virtualCursor==nil)
            let notifications=LiveSnapshotNotifications()
            let token=NotificationCenter.default.addObserver(forName:.init("computerUseAppControllerDidUpdateAppSnapshot"),object:nil,queue:nil) { _ in notifications.add() }
            defer { NotificationCenter.default.removeObserver(token) }
            let first=try await controller!.updateAppSnapshot(disableAXDiffing:false,skipScreenshot:true)
            actualSnapshotExecuted=true
            let firstRevision=first.axTree.selection.value.windowRevision
            firstCount=firstRevision.renderTree.preorder.count
            func nodes(_ tree:ControllerRefetchableAppSnapshotTree)->[EventStreamTransformedNode<EventStreamAXNode>] {
                let revision=tree.selection.value.windowRevision
                return revision.renderTree.preorder.compactMap { $0.elementID.flatMap { revision.item(for:$0)?.node } }
            }
            let firstNodes=nodes(first.axTree)
            let buttonID=first.axTree.findButton(labels:["Owned Apply"])
            check("actual native selection renders the owned button",buttonID != nil && first.attachment.text.contains("Owned Apply"))
            check("actual native selection reads the owned field value",firstNodes.contains { $0.role=="AXTextField" && $0.value=="owned seed" })
            check("actual native selection includes the owned slider",firstNodes.contains { $0.role=="AXSlider" })
            check("native selection owns a live AX invalidation monitor",first.axTree.selection.value.invalidationMonitor?.hasObserver==true)
            check("skipScreenshot follows the native tree-only branch",first.attachment.screenshot==nil && first.attachment.mimeType==nil && first.imageSize==nil && controller!.owner.appSnapshotImageFiles.isEmpty)
            check("native snapshot publishes the actual selected window",controller!.owner.lastWindow?.0==first.axTree.selection.value.applicationWindow.nativeWindow.id && controller!.owner.lastWindow?.0 != 0)
            check("native snapshot publishes the returned tree",controller!.owner.lastAXTree === first.axTree)
            check("native snapshot emits its update notification",notifications.value==1)
            try "mutate".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("mutated").path) {
                try await Task.sleep(for:.milliseconds(10))
            }
            check("owned fixture acknowledges its local form mutation",FileManager.default.fileExists(atPath:directory.appendingPathComponent("mutated").path))
            let second=try await controller!.updateAppSnapshot(disableAXDiffing:false,skipScreenshot:true)
            let secondRevision=second.axTree.selection.value.windowRevision
            secondCount=secondRevision.renderTree.preorder.count
            check("native recapture observes the changed button",second.axTree.findButton(labels:["Owned Updated"]) != nil && second.attachment.text.contains("Owned Updated"))
            check("native recapture observes the changed field value",nodes(second.axTree).contains { $0.role=="AXTextField" && $0.value=="owned changed" })
            check("native recapture retains revision lineage",firstRevision.lineageID==secondRevision.lineageID)
            check("earlier retained snapshot remains immutable",first.attachment.text.contains("Owned Apply") && !first.attachment.text.contains("Owned Updated") && firstNodes.contains { $0.value=="owned seed" })
            if let buttonID {
                let node=firstRevision.item(for:buttonID)?.node
                let newID=second.axTree.findButton(labels:["Owned Updated"])
                let newNode=newID.flatMap { secondRevision.item(for:$0)?.node }
                check("native revisions retain the same button AX identity",node != nil && newNode != nil && CFEqual(node!.element.element,newNode!.element.element))
            } else { check("native revisions retain the same button AX identity",false) }
            check("native recapture replaces the owner's published tree",controller!.owner.lastAXTree === second.axTree && controller!.owner.lastAXTree !== first.axTree)
            check("native recapture emits a second update notification",notifications.value==2)
            let third=try await controller!.updateAppSnapshot(disableAXDiffing:true,skipScreenshot:true)
            check("explicit no-diff recapture still reads current native controls",nodes(third.axTree).contains { $0.role=="AXTextField" && $0.value=="owned changed" } && third.axTree.findButton(labels:["Owned Updated"]) != nil)
            check("all three tree captures keep owner inactive and leave focus unconstructed",!controller!.owner.isActive && controller!.owner.focusEnforcer==nil && controller!.owner.accessibilityAssertion==nil && controller!.owner.virtualCursor==nil)
            let backend=ControllerNativeAppSnapshotBackend(owner:controller!.owner,resources:controller!.resources)
            let context=try backend.focusedContext()
            let geometry=try backend.plan(context,root:nil,skipScreenshot:false)
            let frame=context.context.nativeWindow.frame
            check("native image plan stores the actual selected window origin and extent",controller!.owner.visibleRect==frame)
            check("native image plan stores its scale and screenshot size together",geometry.sizing != nil && controller!.owner.scalingFactor==geometry.sizing?.pointScale && controller!.owner.scaledScreenSize==geometry.sizing?.requestedSize)
            let coordinate=ControllerNativeCoordinateClickBackend(controller:controller!).global(.zero)
            check("native screenshot coordinate zero maps to the actual window origin",coordinate==frame.origin && coordinate.x.isFinite && coordinate.y.isFinite)
            let sentinel=CGRect(x:-31,y:47,width:91,height:107)
            controller!.owner.visibleRect=sentinel;controller!.owner.scalingFactor=3;controller!.owner.scaledScreenSize = .init(width:19,height:23)
            let skipped=try backend.plan(context,root:nil,skipScreenshot:true)
            check("skipScreenshot preserves all prior coordinate geometry",skipped.sizing==nil && controller!.owner.visibleRect==sentinel && controller!.owner.scalingFactor==3 && controller!.owner.scaledScreenSize == .init(width:19,height:23))
            let menu=try backend.plan(context,root:context.window,skipScreenshot:false)
            check("a root override preserves all prior coordinate geometry",menu.sizing==nil && controller!.owner.visibleRect==sentinel && controller!.owner.scalingFactor==3 && controller!.owner.scaledScreenSize == .init(width:19,height:23))
            let imageDirectory=directory.appendingPathComponent("owned-generated-native-buffer",isDirectory:true)
            try FileManager.default.createDirectory(at:imageDirectory,withIntermediateDirectories:true)
            let sink=LiveNativeBufferSink(image:ScreenshotFileCoreChecks.image())
            let imageEnvironment=ControllerNativeScreenshotImageEnvironment(captureBuffer:{try await sink.capture($0)},directory:{sink.directory(imageDirectory)})
            let expectedTitle=controller!.resources.geometry.value("AXTitle",on:ControllerNativeAppSnapshotContext.contextual(context.context.application)) ?? "Unknown"
            var buffered:ControllerNativeAppSnapshotImage?=try await backend.captureImage(context,plan:geometry,cursorWindowID:991,environment:imageEnvironment)
            let generatedURL=buffered!.file.url
            check("native image child sends ordered primary and cursor IDs with crop and planned dimensions",sink.options?.includedWindowIDs==[context.context.nativeWindow.id,991] && sink.options?.cropToFirstWindow==true && sink.options?.imageSize==geometry.sizing?.requestedSize)
            check("native image child preserves opacity shadow and absent-delay defaults",sink.options?.shouldBeOpaque==true && sink.options?.includeWindowShadow==false && sink.options?.delaySeconds==nil)
            check("native image child reads the actual application title for capture",sink.options?.appName==expectedTitle)
            check("native image child creates its file directory only after buffer completion",sink.trace==["buffer","directory"])
            check("native image child encodes generated raster and publishes raster dimensions",CGImageSourceCreateWithURL(generatedURL as CFURL,nil) != nil && buffered?.size == .init(width:2,height:2) && buffered?.geometry.pixelWidth==2 && buffered?.geometry.pixelHeight==2)
            var retained=buffered?.file;buffered=nil
            withExtendedLifetime(retained) {
                check("native generated image survives its retained attachment reference",retained != nil && FileManager.default.fileExists(atPath:generatedURL.path))
            }
            retained=nil
            check("native generated image last ARC release deletes file and registry entry",!FileManager.default.fileExists(atPath:generatedURL.path) && !NativeAppSnapshotImage.removeIfOwned(generatedURL))
            var single:ControllerNativeAppSnapshotImage?=try await backend.captureImage(context,plan:geometry,cursorWindowID:nil,environment:imageEnvironment)
            check("native image child without cursor sends only the primary and disables crop",single != nil && sink.options?.includedWindowIDs==[context.context.nativeWindow.id] && sink.options?.cropToFirstWindow==false)
            single=nil
            let directoryReads=sink.trace.filter {$0=="directory"}.count
            sink.failNext();var caughtBufferFailure=false
            do {_ = try await backend.captureImage(context,plan:geometry,cursorWindowID:nil,environment:imageEnvironment)}
            catch LiveNativeBufferFailure.failed {caughtBufferFailure=true}
            check("native buffer failure propagates without invoking the file writer",caughtBufferFailure && sink.trace.filter {$0=="directory"}.count==directoryReads)
            check("image-child capture alone does not publish or retain files on the owner",controller!.owner.appSnapshotImageFiles.isEmpty)
            let cancelledSink=LiveNativeBufferSink(image:ScreenshotFileCoreChecks.image());cancelledSink.pauseNext()
            let cancelledEnvironment=ControllerNativeScreenshotImageEnvironment(captureBuffer:{try await cancelledSink.capture($0)},directory:{cancelledSink.directory(imageDirectory)})
            var imageTask:Task<ControllerNativeAppSnapshotImage,any Error>?=Task {try await backend.captureImage(context,plan:geometry,cursorWindowID:nil,environment:cancelledEnvironment)}
            while !cancelledSink.hasContinuation {await Task.yield()}
            imageTask!.cancel();cancelledSink.release()
            var cancelledImage:ControllerNativeAppSnapshotImage?=try await imageTask!.value;imageTask=nil
            let cancelledURL=cancelledImage!.file.url
            withExtendedLifetime(cancelledImage) {
                check("cancelled native image child adds no post-buffer checkpoint before file encoding",FileManager.default.fileExists(atPath:cancelledURL.path) && cancelledSink.trace==["buffer","directory"])
            }
            cancelledImage=nil
            check("cancelled native image child still releases its generated file by ARC",!FileManager.default.fileExists(atPath:cancelledURL.path) && !NativeAppSnapshotImage.removeIfOwned(cancelledURL))
            let permitted=CGPreflightScreenCaptureAccess()
            check("actual native image diagnostic has existing capture permission",permitted)
            guard permitted else {throw LiveSnapshotFailure.capturePermissionRequired}
            let fixtureState=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("fixture-state.json"))) as? [String:Any]
            guard let expectedID=(fixtureState?["windowNumber"] as? NSNumber)?.uint32Value,
                  expectedID==context.context.nativeWindow.id,
                  context.context.nativeWindow.processIdentifier==target.processIdentifier else {throw LiveSnapshotFailure.unexpectedFixtureWindow}
            ownedFixtureWindowVerified=true
            check("real native image context matches exact owned fixture window and PID",ownedFixtureWindowVerified)
            let actualDirectory=directory.appendingPathComponent("actual-native-image-files",isDirectory:true)
            var actual:ControllerNativeAppSnapshotImage?=try await backend.captureImage(context,plan:geometry,cursorWindowID:nil)
            actualLiveImageCapture=true
            let actualURL=actual!.file.url
            guard let actualSource=CGImageSourceCreateWithURL(actualURL as CFURL,nil) else {throw LiveSnapshotFailure.missingScreenshot}
            let actualProperties=CGImageSourceCopyPropertiesAtIndex(actualSource,0,nil) as? [CFString:Any]
            let actualWidth=(actualProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let actualHeight=(actualProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let expectedPixels=ControllerScreenshotCapture<ControllerScreenshotCaptureNative>.pixelSize(geometry.sizing!.requestedSize)!
            check("default native image child writes a decodable actual owned capture",actualWidth>0 && actualHeight>0 && FileManager.default.fileExists(atPath:actualURL.path))
            check("actual image child honors planned SDK ceiling dimensions",actualWidth==expectedPixels.width && actualHeight==expectedPixels.height && actual!.size == .init(width:actualWidth,height:actualHeight))
            check("actual image child publishes real raster dimensions and owned geometry",actual!.geometry.pixelWidth==actualWidth && actual!.geometry.pixelHeight==actualHeight && actual!.geometry.windowID==expectedID && actual!.geometry.ownerPID==target.processIdentifier && actual!.geometry.includedWindowIDs==[expectedID])
            check("default native writer uses explicit owned diagnostic directory",actualURL.path.hasPrefix(actualDirectory.path+"/"))
            check("actual writer encoding and MIME match the native plan",CGImageSourceGetType(actualSource).map {$0 as String}==geometry.settings.encoding.type.identifier && actual!.mimeType==geometry.settings.encoding.type.preferredMIMEType)
            check("actual image child alone does not retain a file on the owner",controller!.owner.appSnapshotImageFiles.isEmpty)
            var actualRetained=actual?.file;actual=nil
            withExtendedLifetime(actualRetained) {
                check("actual captured file survives its retained attachment reference",actualRetained != nil && FileManager.default.fileExists(atPath:actualURL.path))
            }
            actualRetained=nil
            check("actual image child last ARC release deletes file and registry entry",!FileManager.default.fileExists(atPath:actualURL.path) && !NativeAppSnapshotImage.removeIfOwned(actualURL))
            var complete:ControllerNativeAppController.AppSnapshot?=try await controller!.updateAppSnapshot(disableAXDiffing:false,skipScreenshot:false)
            actualFullNativeCapture=true
            guard let completeURL=complete?.attachment.screenshot?.url else {throw LiveSnapshotFailure.missingScreenshot}
            let completeProperties=CGImageSourceCreateWithURL(completeURL as CFURL,nil).flatMap {CGImageSourceCopyPropertiesAtIndex($0,0,nil)} as? [CFString:Any]
            let completeWidth=(completeProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let completeHeight=(completeProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            check("full native appSnapshot returns an actual image attachment and MIME",complete!.attachment.screenshot != nil && complete!.attachment.mimeType==geometry.settings.encoding.type.preferredMIMEType && completeWidth>0 && completeHeight>0)
            check("full native appSnapshot joins real AX controls with the captured image",complete!.axTree.findButton(labels:["Owned Updated"]) != nil && nodes(complete!.axTree).contains {$0.role=="AXTextField" && $0.value=="owned changed"})
            check("full native appSnapshot returns decoded actual image dimensions",complete!.imageSize == .init(width:completeWidth,height:completeHeight))
            check("full native appSnapshot retains its exact image file on the owner",controller!.owner.appSnapshotImageFiles.count==1 && controller!.owner.appSnapshotImageFiles.contains(complete!.attachment.screenshot!))
            check("full native appSnapshot publishes matching owned window and tree",controller!.owner.lastWindow?.0==expectedID && controller!.owner.lastAXTree === complete!.axTree)
            check("full native appSnapshot emits exactly its fourth update notification",notifications.value==4)
            check("actual image capture keeps owner inactive without focus or cursor",!controller!.owner.isActive && controller!.owner.focusEnforcer==nil && controller!.owner.accessibilityAssertion==nil && controller!.owner.virtualCursor==nil)
            check("full native image plan restores the actual window coordinate origin",controller!.owner.visibleRect==frame && ControllerNativeCoordinateClickBackend(controller:controller!).global(.zero)==frame.origin)
            complete=nil
            check("owner retains actual capture after returned result releases",FileManager.default.fileExists(atPath:completeURL.path))
            controller!.owner.appSnapshotImageFiles=[]
            check("clearing owner after last attachment release deletes actual captured file",!FileManager.default.fileExists(atPath:completeURL.path) && !NativeAppSnapshotImage.removeIfOwned(completeURL))
            controller=nil
        } catch { errorDescription=String(describing:error) }
        check("native controller owner releases after retained snapshot scope",!nativeOwnerCreated || releasedOwner==nil)
        try? "stop".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<200 where !target.isTerminated { try await Task.sleep(for:.milliseconds(10)) }
        if !target.isTerminated { target.terminate() }
        for _ in 0..<100 where !target.isTerminated { try await Task.sleep(for:.milliseconds(10)) }
        check("owned fixture process and window terminate",target.isTerminated)
        check("native snapshot diagnostic preserves foreground",foreground==NSWorkspace.shared.frontmostApplication?.processIdentifier)
        check("native snapshot composition completes without error",errorDescription==nil && actualSnapshotExecuted)
        let passed=checks.allSatisfy { $0["passed"] as? Bool==true }
        let report:[String:Any]=["passed":passed,"checks":checks,"error":errorDescription as Any? ?? NSNull(),
            "nativeOwnerCreated":nativeOwnerCreated,"actualSnapshotExecuted":actualSnapshotExecuted,
            "firstRenderedNodeCount":firstCount,"secondRenderedNodeCount":secondCount,
            "targetPID":target.processIdentifier,"targetTerminal":target.isTerminated,
            "foregroundUnchanged":foreground==NSWorkspace.shared.frontmostApplication?.processIdentifier,
            "actualNativeOwnerAXSnapshotsTransformationRevisionAttachmentAndPublication":actualSnapshotExecuted,
            "nativeAXSnapshotProvidersIntercepted":false,"ownerActivated":false,"skipScreenshot":false,
            "actualLiveNativeImageChildCapture":actualLiveImageCapture,"actualFullNativeTreeAndImageCapture":actualFullNativeCapture,
            "actualLiveImageChildBufferProviderIntercepted":false,"actualLiveParentCaptureProvidersIntercepted":false,
            "ownedFixtureWindowIDAndPIDVerified":ownedFixtureWindowVerified,"inheritedGeneratedBufferChecks":12,
            "actualInputFocusOrGeneralClipboard":false,
            "actualInputFocusScreenCaptureOrGeneralClipboard":actualLiveImageCapture || actualFullNativeCapture,
            "fullGoalComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native live snapshot: \(checks.filter { $0["passed"] as? Bool==true }.count)/\(checks.count)")
        return passed ? 0:3
    }
}
