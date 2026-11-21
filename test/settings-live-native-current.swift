import AppKit

private final class LiveNativeEvents: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    func add() { lock.withLock { count += 1 } }
    var value:Int { lock.withLock { count } }
}

@MainActor enum OwnedLiveSettingsNativeChecks {
    static func run() async throws {
        typealias Session=SettingsAccessoryTrackingSession<SystemSettingsNativeApplication,NSImage>
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
        var rows=[[String:Any]]()
        func check(_ value:Bool,_ name:String) { rows.append(["name":name,"passed":value]);print("\(value ? "PASS" : "FAIL") \(name)") }
        func panel(_ rectangle:CGRect)->NSPanel {
            let window=NSPanel(contentRect:rectangle,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.backgroundColor = .clear;window.isOpaque=false;window.hasShadow=false
            window.alphaValue=0.001;window.ignoresMouseEvents=true;window.orderFront(nil)
            return window
        }
        func wait(_ condition:()->Bool) async -> Bool {
            for _ in 0..<200 { if condition() { return true };try? await Task.sleep(for:.milliseconds(10)) }
            return condition()
        }
        let tracked=panel(CGRect(x:100,y:100,width:700,height:500))
        let other=panel(CGRect(x:850,y:100,width:180,height:140))
        let destination=panel(CGRect(x:0,y:0,width:531,height:110));destination.orderOut(nil)
        defer { tracked.close();other.close();destination.close() }
        let trackedID=UInt32(tracked.windowNumber),otherID=UInt32(other.windowNumber)
        let native=Session.Tracker.Environment.fullyNative()
        var axStatus="not attempted",permissionPresent=true,captures=0,creations=0,cancels=0,activationHooks=0
        let environment=Session.Tracker.Environment(waitForWindow:native.waitForWindow,onscreenWindows:native.onscreenWindows,
            observeApplication:native.observeApplication,observeWindow:native.observeWindow,
            observeScroll:{ app,request,handler in
                do { let result=try native.observeScroll(app,request,handler);axStatus="registered";return result }
                catch {
                    if let failure=error as? SettingsScrollRegistration<SettingsNativeAXObserver,SettingsNativeAXElement>.Failure { axStatus="add failure:\(failure.status)" }
                    else if let failure=error as? SettingsNativeAXObserver.Failure { axStatus="create failure:\(failure.status)" }
                    else { axStatus="failure:\((error as NSError).code)" }
                    throw error
                }
            },scheduleScroll:native.scheduleScroll)
        let session=Session(trackerEnvironment:environment) { tracker in
            .init(permission:{ permissionPresent ? .init(identifier:"owned",isScreenRecording:true):nil },
                firstScreenHeight:{ NSScreen.screens.first?.frame.height },hasObservedWindow:{ tracker.hasObservedWindow },lastWindow:{ tracker.lastWindow },
                heading:{ _ in nil },withoutTransition:{ false },makeWindow:{ _,_,_ in
                    creations += 1
                    return .init(fittingSize:{ CGSize(width:531,height:110) },frameForContent:{ $0 },
                        setFrame:{ destination.setFrame($0,display:false) },layout:{ destination.layoutIfNeeded() },
                        capture:{ captures += 1;return .init(frameOnScreen:destination.frame,artwork:nil,cornerRadius:14) },
                        setAlphas:{ _ in destination.alphaValue=0.001 },revealAfterForward:{ destination.alphaValue=0.001 },
                        orderFront:{ destination.orderFront(nil) },close:{ destination.orderOut(nil) })
                },makeTransition:{ AppshotPermissionTransition.makeController().presentationTransition() },
                clearTracking:{ tracker.clearTracking() },activateApplication:{ activationHooks += 1 },activateSettings:{ activationHooks += 1 },
                transitionStarted:{},reverseCompleted:{},cancelDrag:{ permissionPresent=false;cancels += 1 },completeDrop:{})
        }
        defer { session.clear() }
        session.prepare(source:nil,transitionsEnabled:true)
        try await session.start(application:SystemSettingsNativeApplication(.current),isScreenRecordingPermission:true)
        check(session.tracker.lastWindow?.identifier==trackedID && creations==1,"fully native initial wait selects the qualifying owned window and drives the actual presenter")
        check(session.tracker.observer === session.presentation && session.presentation.window != nil && destination.isVisible,"native tracker and presentation are connected through the production session")
        check(axStatus != "not attempted","recording tracking attempts the actual AX notification provider and retains its result")
        let initial=session.tracker.lastWindow?.frame
        var changed=tracked.frame;changed.origin.x += 17;changed.size.width += 13
        tracked.setFrame(changed,display:false)
        let moved=await wait { session.tracker.lastWindow?.frame != initial }
        check(moved && session.tracker.lastWindow?.identifier==trackedID,"real WindowServer move/resize callbacks update the production tracker without position polling")
        if let current=session.tracker.lastWindow,let height=NSScreen.screens.first?.frame.height {
            check(destination.frame==SettingsAccessoryLayout.contentFrame(windowQuartz:current.frame,primaryScreenHeight:height,fittingSize:CGSize(width:531,height:110),audioHeading:nil),"native window callback relayouts the owned destination using the accessory layout geometry")
        } else { check(false,"native window callback relayouts the owned destination using the accessory layout geometry") }
        try? await Task.sleep(for:.milliseconds(100))
        let expectedDestination=destination.frame,priorCaptures=captures
        let pipEvents=LiveNativeEvents()
        var pip=RemoteHostedPIPWindowServerObserver(windowIDs:[otherID],events:[.resized]) { _,_ in pipEvents.add() }
        check(pip != nil,"a production PIP observer joins the live native tracking connection")
        var otherFrame=other.frame;otherFrame.size.width += 19;otherFrame.origin.x += 9
        other.setFrame(otherFrame,display:false)
        let pipDelivered=await wait { pipEvents.value>0 }
        try? await Task.sleep(for:.milliseconds(100))
        check(pipDelivered,"foreign PIP resize is actually delivered, establishing the shared-connection test condition")
        // CGWindow.Observer replaces connection-wide IDs, and the Settings
        // callback accepts the delivered descriptor without an extra membership filter.
        let foreignTracked=await wait { session.tracker.lastWindow?.identifier==otherID && captures>priorCaptures }
        check(foreignTracked && destination.frame != expectedDestination,"native Settings callback accepts the replacement PIP window")
        try? await Task.sleep(for:.milliseconds(150))
        let beforeUnrequested=captures,lastForeign=session.tracker.lastWindow
        changed=tracked.frame;changed.size.width += 11
        tracked.setFrame(changed,display:false)
        try? await Task.sleep(for:.milliseconds(200))
        check(captures==beforeUnrequested && session.tracker.lastWindow==lastForeign,"replaced native request stops geometry delivery for the former Settings window")
        tracked.close()
        try? await Task.sleep(for:.milliseconds(200))
        check(cancels==0 && session.tracker.observedApplication != nil && session.presentation.window != nil && session.tracker.lastWindow?.identifier==otherID,"closing an unrequested former window leaves the replacement observation active")
        let beforePIP=pipEvents.value,beforeClearCaptures=captures
        session.clear()
        check(session.tracker.observedApplication==nil && !session.tracker.hasObservedWindow && session.presentation.window==nil && session.tracker.lastWindow?.identifier==otherID,"explicit native tracker cleanup retains the last-window cache while releasing presentation")
        otherFrame=other.frame;otherFrame.size.width += 7
        other.setFrame(otherFrame,display:false)
        let pipSurvives=await wait { pipEvents.value>beforePIP }
        try? await Task.sleep(for:.milliseconds(100))
        check(pipSurvives && session.presentation.window==nil && captures==beforeClearCaptures && cancels==0,"PIP survives Settings registration release without a union reset or a late presentation reopen")
        pip=nil
        other.setFrame(CGRect(x:100,y:100,width:710,height:510),display:false)
        session.prepare(source:nil,transitionsEnabled:true)
        try await session.start(application:SystemSettingsNativeApplication(.current),isScreenRecordingPermission:true)
        check(session.tracker.lastWindow?.identifier==otherID && creations==2 && destination.isVisible,"a new native tracker session recovers on the remaining qualifying owned window")
        other.close()
        let closed=await wait { cancels==1 }
        check(closed && session.tracker.observedApplication==nil && session.presentation.window==nil && !destination.isVisible,"the requested native window close clears tracking and presentation and cancels exactly once")
        check(front==NSWorkspace.shared.frontmostApplication?.processIdentifier && !NSApp.isActive && !tracked.isKeyWindow && !other.isKeyWindow && !destination.isKeyWindow,"all transparent owned native windows preserve the original foreground and key focus")
        check(tracked.ignoresMouseEvents && other.ignoresMouseEvents && destination.ignoresMouseEvents,"native integration panels pass mouse events through")
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any]=["passed":passed,"cases":rows.count,"results":rows,"axRegistration":axStatus,"axRegistrationSucceeded":axStatus=="registered","capturesAreOwnedMetadataOnly":true,
            "productionTrackerPresenterSessionAndNativeWindowProvidersExecuted":true,"nativeAXProviderAttempted":true,"nativeAXHeadingExtractionExecuted":false,"nativeKVOActivityTransitionsTriggered":false,
            "nativeActivationHooksExecuted":false,"activationHooksControlled":activationHooks,"permissionGrantOrInputOrScreenCaptureExecuted":false,"transparentNonactivatingMouseTransparentPanelsOnly":true,
            "fullPermissionCoordinatorExecuted":false,"ownedClockOverlayUsed":false,"sourceCaptureAbsent":true]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native-result.json"))
        if !passed { throw NSError(domain:"OwnedLiveSettingsNativeChecks",code:1) }
    }
}
