import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import ScreenCaptureKit

@MainActor final class NativePIPRendererLifecycleChecks: NSObject, NSApplicationDelegate {
    private enum Failure: Error { case fixtureNotReady, noWindow, noImage, sampleCreation }
    private let output: URL, fixture: URL, directory: URL
    init(output: URL, fixture: URL, directory: URL) { self.output=output;self.fixture=fixture;self.directory=directory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { exit(try await run()) }
            catch {
                try? JSONSerialization.data(withJSONObject:["passed":false,"error":String(describing:error)],options:[.prettyPrinted])
                    .write(to:output)
                exit(2)
            }
        }
    }
    private static func containsVisibleCursorPixels(_ image:CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(image,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(image) else { return false }
        let bytes=base.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(image)
        for y in 0..<CVPixelBufferGetHeight(image) {
            for x in 0..<CVPixelBufferGetWidth(image) {
                let offset=y*stride+x*4
                if bytes[offset+3]>16 && max(bytes[offset],bytes[offset+1],bytes[offset+2])>24 { return true }
            }
        }
        return false
    }

    private func run() async throws -> Int32 {
        var checks:[[String:Any]]=[]
        func check(_ name:String,_ passed:Bool) { checks.append(["name":name,"passed":passed]);if !passed { print("FAIL: "+name) } }
        let foreground=NSWorkspace.shared.frontmostApplication?.processIdentifier
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=false;configuration.createsNewApplicationInstance=true
        let target=try await NSWorkspace.shared.openApplication(at:fixture,configuration:configuration)
        var renderer:RemoteHostedPIPWindowRenderer?
        weak var releasedRenderer:RemoteHostedPIPWindowRenderer?
        var frameCount=0,unavailableCount=0,refreshCount=0,imageAspectChecks=0
        var lastImage:CVPixelBuffer?
        var events:[String]=[]
        var cursorRefreshActive=0,resizeChanged=0,resizeSettled=0
        var hosted:NativePIPHostedChecks.Session?
        var hostedReport:[String:Any]=[:]
        var failure:String?
        var actualCapture=false
        var cursorFrames=0,cursorLayoutChecks=0,coloredCursorFrames=0
        var cursorGeometrySnapshot:[String:String]=[:]
        var ownedCursor:CursorOverlay?
        let nativeProducer=try RemoteHostedPIPContentProducer()
        let cursorRoot=nativeProducer.rootLayer
        var closedWindowMetadataRemained:Bool?
        var closedWindowWasOnScreen:Bool?
        var fixtureCloseReceipt:[String:Any]?
        do {
            for _ in 0..<150 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) {
                try await Task.sleep(for:.milliseconds(10))
            }
            guard !target.isTerminated,let state=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("fixture-state.json"))) as? [String:Any],
                  let raw=state["windowNumber"] as? NSNumber else { throw Failure.fixtureNotReady }
            let id=raw.uint32Value
            guard let window=ControllerWindowDescription.lookup(id) else { throw Failure.noWindow }
            check("fixture ID and PID belong to the owned inactive application",id != 0 && window.ownerPID==target.processIdentifier && state["keyWindow"] as? Bool==false)
            let capture=RemoteHostedPIPWindowRenderer(windowID:id,associatedWindowIDs:[],onCursorFrame:{ image in cursorFrames += 1;if Self.containsVisibleCursorPixels(image) { coloredCursorFrames += 1 } }) { image in
                frameCount += 1;lastImage=image
                if let aspect=releasedRenderer?.diagnosticState.latestPresentationAspect,
                   aspect.reason=="sample-image-buffer",
                   aspect.sourceSize==CGSize(width:CVPixelBufferGetWidth(image),height:CVPixelBufferGetHeight(image)) {
                    imageAspectChecks += 1
                }
            }
            renderer=capture
            releasedRenderer=capture
            capture.diagnosticEventHandler={ event in
                events.append(event)
                if event.hasPrefix("geometry:"){refreshCount += 1}
                if event=="cursor-refresh:begin"{cursorRefreshActive += 1}
                if event=="cursor-refresh:end"{cursorRefreshActive -= 1}
            }
            capture.setSourceUnavailableHandler { unavailableCount += 1 }
            capture.setGeometryResizeHandlers(changed:{ _ in resizeChanged += 1 },settled:{ [weak capture] size in
                resizeSettled += 1
                // This direct renderer diagnostic supplies its own host completion.
                // The separately owned service below verifies the ordinary XPC path.
                capture?.setFrameDeliverySuspended(false)
            })
            let preparedSize=try await capture.prepare(producer:nativeProducer,isActive:true,maxDisplaySize:200)
            check("actual prepare attaches exact native layers and selected size",cursorRoot.sublayers?.count==2 && cursorRoot.frame.size==preparedSize && cursorRoot.backgroundColor==NSColor.clear.cgColor)
            check("actual prepare installs finish observer before returning",capture.diagnosticState.hasCursorObserver)
            for _ in 0..<150 where frameCount==0 { try await Task.sleep(for:.milliseconds(10)) }
            actualCapture=frameCount>0
            check("actual PIP CaptureStream delivers pixels through the native wrapper",actualCapture && lastImage != nil)
            let initial=capture.diagnosticState
            check("native geometry observer and main capture are retained",initial.hasGeometryObserver && initial.hasMainCapture && initial.hasCaptureGeometry && !initial.sourceUnavailable)
            check("native independent capture key preserves exact owned window ID",initial.captureKey?.windowIDs==[id] && initial.captureKey?.displayID==nil)
            check("native capture key reads configuration source rectangle",initial.captureKey.map { CGRectEqualToRect($0.sourceRect,SCStreamConfiguration().sourceRect) && $0.pixelSize.width>=1 && $0.pixelSize.height>=1 } ?? false)
            check("actual image dimensions drive presentation aspect at callback time",imageAspectChecks>0)
            check("first native aspect resolves presentation wait",initial.currentPresentationSize != nil && initial.latestPresentationAspect != nil && !initial.hasPendingPresentation && initial.latestAspectGeneration==initial.captureGeneration)
            capture.diagnosticCursorLayoutHandler={ geometry,cachedBounds,frame,hidden in
                if cachedBounds==geometry.targetBounds,
                   geometry.layout(superlayerBounds:cursorRoot.bounds) == .frame(frame),!hidden { cursorLayoutChecks += 1 }
            }
            let overlay=CursorOverlay();ownedCursor=overlay
            guard let cursorTarget=capture.diagnosticState.targetBounds else { throw Failure.noWindow }
            overlay.place(at:CGPoint(x:cursorTarget.minX+min(70,cursorTarget.width/2),y:cursorTarget.minY+min(70,cursorTarget.height/2)),animated:false,targetWindowID:id)
            await capture.diagnosticRefreshCursorCapture()
            for _ in 0..<150 where coloredCursorFrames==0 { try await Task.sleep(for:.milliseconds(10)) }
            for _ in 0..<150 where cursorRefreshActive != 0 {try await Task.sleep(for:.milliseconds(10))}
            let cursorState=capture.diagnosticState
            check("actual registered visible cursor produces a native display capture",cursorState.hasCursorCapture && cursorState.cursorCaptureKey?.windowID==overlay.currentVisibleWindowID() && cursorFrames>0)
            check("actual native cursor crop contains visible colored cursor pixels",coloredCursorFrames>0)
            cursorGeometrySnapshot=["initialCGWindow":NSStringFromRect(window.bounds),
                "mainCachedBounds":cursorState.targetBounds.map(NSStringFromRect) ?? "nil",
                "cursorTarget":cursorState.cursorLayerGeometry.map { NSStringFromRect($0.targetBounds) } ?? "nil",
                "cursorClipped":cursorState.cursorLayerGeometry.map { NSStringFromRect($0.clippedBounds) } ?? "nil",
                "cursorHidden":String(cursorState.cursorHidden)]
            check("actual cursor layer geometry uses cached source and clipped bounds at layout time",cursorLayoutChecks>0)
            await capture.diagnosticRefreshCursorCapture()
            check("unchanged native cursor key keeps stream and generation",capture.diagnosticState.cursorCaptureKey==cursorState.cursorCaptureKey && capture.diagnosticState.cursorGeneration==cursorState.cursorGeneration && capture.diagnosticState.hasCursorCapture)
            overlay.hide()
            await capture.diagnosticRefreshCursorCapture()
            check("no visible registered cursor clears capture key geometry and layer",!capture.diagnosticState.hasCursorCapture && capture.diagnosticState.cursorCaptureKey==nil && capture.diagnosticState.cursorLayerGeometry==nil && capture.diagnosticState.cursorHidden)
            check("native cursor clear advances generation exactly once",capture.diagnosticState.cursorGeneration==cursorState.cursorGeneration+1)
            let beforeDisplay=frameCount
            capture.setAssociatedWindowIDs([id])
            for _ in 0..<200 where capture.diagnosticState.captureKey?.windowIDs != [id,id] || capture.diagnosticState.frameDeliverySuspended {try await Task.sleep(for:.milliseconds(10))}
            for _ in 0..<150 where frameCount==beforeDisplay { try await Task.sleep(for:.milliseconds(10)) }
            let displayKey=capture.diagnosticState.captureKey
            check("actual display filter accepts duplicated primary associated ID",displayKey?.windowIDs==[id,id] && displayKey?.displayID != nil)
            check("actual display capture delivers owned-window pixels",frameCount>beforeDisplay && capture.diagnosticState.latestAspectGeneration==capture.diagnosticState.captureGeneration)
            capture.setAssociatedWindowIDs([])
            for _ in 0..<200 where capture.diagnosticState.captureKey?.windowIDs != [id] || capture.diagnosticState.frameDeliverySuspended {try await Task.sleep(for:.milliseconds(10))}
            check("actual independent filter restores singleton capture key",capture.diagnosticState.captureKey?.windowIDs==[id] && capture.diagnosticState.captureKey?.displayID==nil)
            let imageChecksBeforeResize=imageAspectChecks
            try "resize".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
            for _ in 0..<200 where refreshCount==0 { try await Task.sleep(for:.milliseconds(10)) }
            try await Task.sleep(for:.milliseconds(600))
            check("real resize reaches renderer geometry notifications",refreshCount>0 && events.contains{$0.hasPrefix("geometry:")})
            check("named native AX notification bridge delivers resize reasons",events.contains{$0=="geometry:AX.resized" || $0=="geometry:AX.windowResized"})
            check("resize capture resumes physical frame delivery",frameCount>1 && !capture.diagnosticState.frameDeliverySuspended && !capture.diagnosticState.sourceUnavailable)
            check("resized capture keeps generation-tagged native aspect",capture.diagnosticState.latestAspectGeneration==capture.diagnosticState.captureGeneration && capture.diagnosticState.latestPresentationAspect != nil && imageAspectChecks>imageChecksBeforeResize && !capture.diagnosticState.hasPendingPresentation)
            check("real source resize invokes distinct changed and settled callbacks",resizeChanged>0 && resizeSettled>0)
            let session=try NativePIPHostedChecks.Session(directory:directory);hosted=session
            try await session.start(windowID:id,targetPID:target.processIdentifier)
            try await session.resize()
            try await session.associationUpdates(windowID:id)
            if let expected=session.latest["bounds"] as? [Double],expected.count==4 {
                let bounds=CGRect(x:expected[0],y:expected[1],width:expected[2],height:expected[3])
                for _ in 0..<200 where capture.diagnosticState.targetBounds != bounds || capture.diagnosticState.frameDeliverySuspended || cursorRefreshActive != 0 {
                    try await Task.sleep(for:.milliseconds(10))
                }
                check("direct and hosted renderers settle to the same native source bounds",capture.diagnosticState.targetBounds==bounds && !capture.diagnosticState.frameDeliverySuspended && cursorRefreshActive==0)
            } else {check("direct and hosted renderers settle to the same native source bounds",false)}
            let beforeClose=capture.diagnosticState
            try "close-window".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
            for _ in 0..<200 where unavailableCount==0 { try await Task.sleep(for:.milliseconds(10)) }
            try await Task.sleep(for:.milliseconds(80))
            try await session.sourceClosed()
            await session.stop();hostedReport=session.report
            checks.append(contentsOf:session.checks);hosted=nil
            let lost=capture.diagnosticState
            let closeReceipt=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("close-state.json"))) as? [String:Any]
            fixtureCloseReceipt=closeReceipt
            let remainingDescription=ControllerWindowDescription.lookup(id)
            closedWindowMetadataRemained=remainingDescription != nil
            closedWindowWasOnScreen=remainingDescription?.isOnscreen
            check("owned fixture confirms actual window closure without deallocation",
                (closeReceipt?["pid"] as? NSNumber)?.int32Value==target.processIdentifier &&
                (closeReceipt?["windowNumber"] as? NSNumber)?.uint32Value==id &&
                closeReceipt?["closeRequested"] as? Bool==true && closeReceipt?["visible"] as? Bool==false && closeReceipt?["keyWindow"] as? Bool==false)
            check("actual closed window delivers one source-unavailable callback",unavailableCount==1 && lost.sourceUnavailable)
            check("source loss advances geometry, main and cursor generations",lost.geometryGeneration>=beforeClose.geometryGeneration+1 && lost.captureGeneration==beforeClose.captureGeneration+1 && lost.cursorGeneration==beforeClose.cursorGeneration+1)
            check("source loss suspends delivery and hides cursor",lost.frameDeliverySuspended && lost.cursorHidden)
            check("source loss preserves aspect cache while invalidating its generation",lost.latestAspectGeneration==beforeClose.captureGeneration && lost.latestPresentationAspect != nil && lost.latestAspectGeneration != lost.captureGeneration && !lost.hasPendingPresentation)
            check("source loss preserves main capture and key until separate stop",lost.hasMainCapture && lost.hasCaptureGeometry)
            capture.diagnosticSourceUnavailable("duplicate diagnostic event")
            capture.diagnosticCaptureStopped(generation:beforeClose.captureGeneration,error:Failure.noWindow)
            check("duplicate loss and stale native error neither notify nor advance",unavailableCount==1 && capture.diagnosticState.captureGeneration==lost.captureGeneration && capture.diagnosticState.geometryGeneration==lost.geometryGeneration && capture.diagnosticState.cursorGeneration==lost.cursorGeneration)
            guard let image=lastImage else { throw Failure.noImage }
            var format:CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:image,formatDescriptionOut:&format)==noErr,
                  let format else { throw Failure.sampleCreation }
            var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
            var sample:CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:image,formatDescription:format,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,
                  let sample else { throw Failure.sampleCreation }
            let count=frameCount
            capture.diagnosticDeliver(sample,generation:beforeClose.captureGeneration)
            check("stale native sample cannot deliver pixels after source loss",frameCount==count)
            capture.diagnosticDeliver(sample,generation:lost.captureGeneration)
            check("current generation while suspended still cannot deliver pixels",frameCount==count)
            await capture.stop()
            let stopped=capture.diagnosticState
            check("separate native stop detaches capture and geometry observer",!stopped.hasMainCapture && !stopped.hasCaptureGeometry && !stopped.hasGeometryObserver && stopped.cursorHidden)
            check("separate stop invalidates all three generations again",stopped.geometryGeneration==lost.geometryGeneration+1 && stopped.captureGeneration==lost.captureGeneration+1 && stopped.cursorGeneration==lost.cursorGeneration+1)
            await capture.stop()
            check("second stop still increments the checked capture generation",capture.diagnosticState.captureGeneration==stopped.captureGeneration+1)
        } catch { failure=String(describing:error) }
        if let hosted { await hosted.stop();hostedReport=hosted.report;checks.append(contentsOf:hosted.checks) }
        ownedCursor?.hide()
        ownedCursor=nil
        await renderer?.stop()
        renderer=nil
        nativeProducer.invalidate()
        check("native renderer and weak callback owners release",releasedRenderer==nil)
        try? "stop".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<200 where !target.isTerminated { try await Task.sleep(for:.milliseconds(10)) }
        if !target.isTerminated { target.terminate() }
        for _ in 0..<100 where !target.isTerminated { try await Task.sleep(for:.milliseconds(10)) }
        check("owned fixture terminates",target.isTerminated)
        check("native test preserves foreground application",foreground==NSWorkspace.shared.frontmostApplication?.processIdentifier)
        check("native PIP lifecycle completes without error",failure==nil && actualCapture)
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        let report:[String:Any]=["passed":passed,"checks":checks,"error":failure as Any? ?? NSNull(),
            "actualPIPNativeCapture":actualCapture,"nativeAXResizeObserved":events.contains{$0=="geometry:AX.resized" || $0=="geometry:AX.windowResized"},
            "events":events,"frameCount":frameCount,"geometryRefreshes":refreshCount,"sourceUnavailableCallbacks":unavailableCount,
            "closedWindowMetadataRemained":closedWindowMetadataRemained as Any? ?? NSNull(),
            "closedWindowWasOnScreen":closedWindowWasOnScreen as Any? ?? NSNull(),
            "fixtureCloseReceipt":fixtureCloseReceipt as Any? ?? NSNull(),
            "actualHostedNativeWindowXPC":hostedReport,"rawRendererHostCallbacksExplicitlySupplied":true,
            "actualRegisteredCursorFrames":cursorFrames,"actualVisibleColoredCursorFrames":coloredCursorFrames,
            "atomicCursorLayoutChecks":cursorLayoutChecks,"cursorGeometrySnapshot":cursorGeometrySnapshot,
            "ownedVisualCursorWindowUsed":true,"systemPointerMoved":false,
            "atomicImageAspectChecks":imageAspectChecks,"targetPID":target.processIdentifier,"targetTerminal":target.isTerminated,"physicalInputOrFocusExecuted":false,
            "nativeCaptureAndAXProvidersIntercepted":false,"fullGoalComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native PIP renderer lifecycle: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
