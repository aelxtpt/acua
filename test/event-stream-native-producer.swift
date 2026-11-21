import Foundation
import AppKit
import ApplicationServices

@MainActor private final class Sleeper {
    var delays:[Duration]=[],pending:[Int:CheckedContinuation<Void,Error>]=[:]
    func sleep(_ delay:Duration) async throws {
        let index=delays.count;delays.append(delay)
        try await withCheckedThrowingContinuation {pending[index]=$0}
    }
    func finish(_ index:Int,error:Error?=nil) {
        guard let continuation=pending.removeValue(forKey:index) else {return}
        if let error {continuation.resume(throwing:error)} else {continuation.resume()}
    }
    func finishAll() {for index in Array(pending.keys) {finish(index)}}
}
private final class Observation:EventStreamAXObservation {
    let callback:(EventStreamAXNotificationEvent)->Void
    var registered:[String]=[],starts=0,stops=0
    init(_ callback:@escaping (EventStreamAXNotificationEvent)->Void) {self.callback=callback}
    func register(_ notification:String,for element:AXUIElement)throws {registered.append(notification)}
    func start() {starts += 1}
    func stop() {stops += 1}
}
@MainActor private final class Fixture {
    let app=NSRunningApplication.current,clock=Sleeper(),hub=EventStreamFrontmostObservers<NSRunningApplication>()
    let element=AXUIElementCreateApplication(-66000),window=AXUIElementCreateApplication(-66001)
    let envelope:AXObserver
    var now=100.0,frontmostPresent=true,input:((EventStreamInputObservation)->Void)?
    var observations:[Observation]=[],trace:[String]=[],observationAttempts=0,observationFailures=0,captureFailures=0
    var failObservation=false,failCapture=false,noChange=false
    var pauseCapture=false,captureWaiters:[CheckedContinuation<Void,Never>]=[]
    var captureTargets:[EventStreamEventTarget?]=[],captureDiffs:[Bool]=[],source:EventStreamNativeSelectionRecordFactory?
    var configurationReads=0
    init() {
        var observer:AXObserver?
        precondition(AXObserverCreate(getpid(),{_,_,_,_ in},&observer) == .success)
        envelope=observer!
    }
    func make()->EventStreamNativeRecorder {
        var io=EventStreamNativeRecorderIO.native
        io.makeInputSource={_,handler in self.trace.append("input.start");self.input=handler;return .init(stop:{self.trace.append("input.stop");self.input=nil})}
        io.addFrontmost={self.trace.append("frontmost.add");return self.hub.add($0)}
        io.removeFrontmost={self.trace.append("frontmost.remove");self.hub.remove($0)}
        io.frontmost={self.frontmostPresent ? self.app:nil}
        io.runningApplication={pid in precondition(pid==self.app.processIdentifier);return self.app}
        // Controlled metadata for eligibility, without changing a system app,
        // bundle, secure-input owner or preference on the machine.
        io.bundleIdentifier={_ in "com.apple.Terminal"}
        io.applicationSnapshot={app in precondition(app === self.app);return .init(name:"Denied App",secureInput:false,processIdentifier:app.processIdentifier)}
        io.textContext={_ in (.init(name:"Text App",secureInput:false,processIdentifier:self.app.processIdentifier),.init(title:"Text Window",windowID:77))}
        io.terminalIO = .init(secureInputPID:{Int(self.app.processIdentifier)},application:{.init(name:"Terminal",secureInput:true,processIdentifier:$0,bundleIdentifier:"com.apple.Terminal")})
        io.observationBackend = .init(application:{_ in self.element},observer:{_,handler in
            self.observationAttempts += 1;self.trace.append("AX.make")
            if self.failObservation {throw EventStreamNativeAXObserver.Failure(status:.cannotComplete)}
            let observation=Observation(handler);self.observations.append(observation);return observation
        })
        io.observationFailed={_,_ in self.observationFailures += 1}
        io.captureFailed={_ in self.captureFailures += 1}
        io.makeCapture={source,configuration in
            self.source=source
            return .init(capture:{target,preferDiff in
                self.trace.append("capture");self.captureTargets.append(target);self.captureDiffs.append(preferDiff)
                self.configurationReads += 1;precondition(configuration()["owned_fixture"] as? Bool == true)
                if self.pauseCapture {await withCheckedContinuation {self.captureWaiters.append($0)}}
                if self.failCapture {throw EventStreamCaptureContextError.noPrimaryWindow}
                source.context.resolver.recordCapturedURL(URL(string:"https://capture.example/shared"),for:77)
                return .init(ax:.init(mode:.fullTree,text:self.noChange ? "no_change":"tree"),
                    app:.init(name:"Capture App",secureInput:false,processIdentifier:self.app.processIdentifier),
                    window:.init(title:"Capture Window",windowID:77))
            },clearPreviousRevision:{self.trace.append("revision.clear")},clearPreviousWindowID:{self.trace.append("window.clear")})
        }
        return EventStreamNativeRecorderFactory.make(prefetchConfiguration:{["owned_fixture":true]},io:io,now:{self.now += 1;return Date(timeIntervalSince1970:self.now)},sleep:clock.sleep)
    }
    func transaction(_ title:String="Before")->EventStreamNativeTreeTransaction {
        var range=CFRange(location:1,length:3)
        let values:[String:AnyObject]=["AXRole":"AXTextArea" as NSString,"AXTitle":title as NSString,"AXValue":"output" as NSString,
            "AXSubrole":NSNull(),"AXDescription":NSNull(),"AXPlaceholderValue":NSNull(),"AXIdentifier":"area" as NSString,
            "AXSelectedTextRange":AXValueCreate(.cfRange,&range)!,"AXSelectedText":"selected" as NSString,"AXWindow":window,"AXParent":NSNull()]
        return .init(root:element,snapshots:.init(attributeTable:[.init(element:element):values,
            .init(element:window):["AXRole":"AXWindow" as NSString,"AXTitle":"Captured Window" as NSString,"AXURL":URL(string:"https://terminal.example/window")! as NSURL]],
            requestedAttributes:EventStreamSnapshotAttributes.common.union(["AXWindow","AXParent","AXSelectedTextRange","AXSelectedText"])),partialValues:[:],roleFrequency:[:])
    }
    func notification(_ name:String) {
        observations.last!.callback(.init(observer:envelope,element:element,notification:name,userInfo:["fixture":"owned" as NSString]))
    }
    func key(_ text:String="",code:UInt16=53) {
        input?(.init(type:.keyDown,location:.zero,flags:[],target:.init(processIdentifier:-66000),clickCount:0,
            keyCode:code,characters:text,charactersIgnoringModifiers:text))
    }
    func finishCaptures() {let waiters=captureWaiters;captureWaiters=[];for waiter in waiters {waiter.resume()}}
}

@main enum Tests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let application=NSApplication.shared
        _=application.setActivationPolicy(.prohibited)
        var checks=0
        func check(_ label:String,_ value:Bool) {
            guard value else {print("FAIL: \(label)");fatalError(label)}
            checks += 1;print("PASS: \(label)")
        }
        func drain() async {for _ in 0..<50 {await Task.yield()}}
        let fixture=Fixture();let recorder=fixture.make();var records:[EventStreamRecord]=[]
        check("fixture has registered its own valid AppKit process",fixture.app.processIdentifier==getpid())
        recorder.onRecordStored={records.append($0)}
        check("native construction is lazy and installs no source",fixture.trace.isEmpty && !recorder.isRecording && recorder.sequence==0)
        try recorder.start();await drain()
        check("native start binds capture reset input frontmost and AX owners",Array(fixture.trace.prefix(5))==["revision.clear","window.clear","input.start","frontmost.add","AX.make"])
        check("native observer installs the Terminal notifications",fixture.observations[0].registered==EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:"com.apple.Terminal") && fixture.observations[0].starts==1)
        check("native initial boundary and app transition share sequence",records.map(\.id)==[1,2] && records.map(\.kind)==[.sessionStarted,.windowChanged] && recorder.sequence==2)
        check("application transition captures current context without explicit target",fixture.captureTargets.count==1 && fixture.captureTargets[0]==nil && fixture.captureDiffs==[true])
        check("native capture receives explicit recorder configuration",fixture.configurationReads==1)
        check("native capture and selection source share URL cache owner",fixture.source?.context.resolver.windowURLs[77]?.absoluteString=="https://capture.example/shared")
        try recorder.start();await drain();check("repeated native start installs no second sources",fixture.observationAttempts==1 && records.count==2)
        EventStreamTreeTransactions.$current.withValue(fixture.transaction()) {fixture.notification("AXSelectedTextChanged")};await drain()
        EventStreamTreeTransactions.$current.withValue(fixture.transaction()) {fixture.notification("AXValueChanged")};await drain()
        fixture.key("t",code:0);await drain()
        check("native input selection and terminal keep independent delays",fixture.clock.delays==[.milliseconds(500),.milliseconds(750),.milliseconds(750)] && recorder.sequence==5 && records.count==2)
        EventStreamTreeTransactions.$current.withValue(fixture.transaction("After")) {recorder.flushPendingRecords()}
        check("native explicit flush uses text terminal selection ordering",records.suffix(3).map(\.kind)==[.keyboardTextInput,.terminalValueChanged,.selectionChanged])
        check("one native sequence spans keys flush selection and terminal",records.map(\.id)==[1,2,6,4,3] && recorder.sequence==6)
        check("native text is preserved through composed input and flush",records[2].keyboard?.text=="t" && records[2].app?.name=="Text App")
        check("native terminal refreshes target while preserving entry context",records[3].keyboard?.target?.title=="After" && records[3].window?.title=="Captured Window" && records[3].app?.secureInput==true)
        check("native selection queue preserves captured target and text",records[4].selection?.target?.title=="Before" && records[4].selection?.selectedText=="selected")
        fixture.clock.finishAll();await drain();check("explicit native flush cancels duplicate timer emissions",records.count==5 && fixture.clock.pending.isEmpty)
        let focusEntry=fixture.now+1
        fixture.notification("AXFocusedWindowChanged");await drain()
        check("focused window schedules250ms and allocates callback-entry identity",fixture.clock.delays.last == .milliseconds(250) && recorder.sequence==7)
        fixture.clock.finish(3);await drain()
        check("focused-window capture preserves its original timestamp",records.last?.id==7 && records.last?.timestamp==Date(timeIntervalSince1970:focusEntry) && records.last?.kind == .windowChanged)
        check("focused-window native capture also has no explicit target",fixture.captureTargets.count==2 && fixture.captureTargets[1]==nil)
        fixture.key();await drain();fixture.clock.finish(4,error:CocoaError(.userCancelled));await drain()
        check("composed native shortcut survives noncancellation delay error",records.last?.id==8 && records.last?.kind == .keyboardShortcut && records.last?.keyboard?.keyEquivalent=="escape")
        check("input native capture retains original explicit target identity",fixture.captureTargets.last.flatMap{$0}?.identity.processIdentifier == -66000)
        let beforePolicy=records.count
        recorder.shouldCaptureApplication={_ in false};await drain()
        check("policy setter alone does not manufacture refresh records",records.count==beforePolicy)
        recorder.refreshCurrentApplication();await drain()
        check("denied transition emits plain app metadata without capture",records.last?.kind == .windowChanged && records.last?.app?.name=="Denied App" && records.last?.ax==nil && fixture.captureTargets.count==3)
        check("denied transition stops old AX observer",fixture.observations[0].stops==1)
        let deniedSequence=recorder.sequence
        EventStreamTreeTransactions.$current.withValue(fixture.transaction()) {fixture.notification("AXSelectedTextChanged")};await drain()
        check("late delivered notification reevaluates latest application policy",recorder.sequence==deniedSequence && fixture.clock.pending.isEmpty)
        recorder.shouldCaptureApplication=nil;recorder.refreshCurrentApplication();await drain()
        check("allowed policy refresh reinstalls observer on same PID",fixture.observationAttempts==2 && fixture.observations[1].starts==1 && fixture.captureTargets.count==4)
        let beforeStop=fixture.trace.count;recorder.stop(emitSessionEnded:true)
        check("native stop tears down input subscription and observer",Array(fixture.trace.dropFirst(beforeStop))==["input.stop","frontmost.remove","window.clear"] && fixture.observations[1].stops==1 && fixture.input==nil)
        check("native stop clears shared URL state but retains revision reset count",fixture.source?.context.resolver.windowURLs.isEmpty==true && fixture.trace.filter{$0=="revision.clear"}.count==1 && !recorder.isRecording)
        let sequenceAfterStop=recorder.sequence
        try recorder.start();await drain()
        check("native restart resets predecessor while continuing sequence",fixture.trace.filter{$0=="revision.clear"}.count==2 && recorder.sequence==sequenceAfterStop+2)
        recorder.stop(emitSessionEnded:false);fixture.clock.finishAll();await drain()

        let failure=Fixture();failure.failObservation=true
        let failureRecorder=failure.make();var failures:[EventStreamRecord]=[];failureRecorder.onRecordStored={failures.append($0)}
        try failureRecorder.start();await drain()
        check("observer setup failure still schedules native window record",failure.observationFailures==1 && failures.map(\.kind)==[.sessionStarted,.windowChanged])
        failureRecorder.refreshCurrentApplication();await drain()
        check("same-PID observer failure is retried by native application controller",failure.observationAttempts==2 && failure.observationFailures==2 && failures.last?.id==3)
        failure.failObservation=false;failure.failCapture=true;failureRecorder.refreshCurrentApplication();await drain()
        check("native capture failure recovers without synthetic AX or debug event",failure.captureFailures==1 && failures.last?.kind == .windowChanged && failures.last?.ax==nil && failures.last?.app==nil)
        failureRecorder.stop(emitSessionEnded:false)

        let late=Fixture();late.pauseCapture=true
        let lateRecorder=late.make();var lateRecords:[EventStreamRecord]=[];lateRecorder.onRecordStored={lateRecords.append($0)}
        try lateRecorder.start();await drain()
        check("native async capture can be outstanding after initial boundary",late.captureWaiters.count==1 && lateRecords.map(\.kind)==[.sessionStarted])
        lateRecorder.stop(emitSessionEnded:false);late.finishCaptures();await drain()
        check("already-running native capture completion has no new recording gate",!lateRecorder.isRecording && lateRecords.last?.kind == .windowChanged && lateRecords.last?.id==2)

        // Every independently delayed component must retain the full recorder,
        // not merely its child, then release it after actual completion.
        for kind in ["text","shortcut","selection","terminal","layout"] {
            let lifetime=Fixture();lifetime.frontmostPresent = !["text","shortcut"].contains(kind)
            var owner:EventStreamNativeRecorder?=lifetime.make();var outputs:[EventStreamRecord]=[]
            owner!.onRecordStored={outputs.append($0)};try owner!.start();await drain()
            switch kind {
            case "text":lifetime.key("x",code:0)
            case "shortcut":lifetime.key()
            case "selection":EventStreamTreeTransactions.$current.withValue(lifetime.transaction()) {lifetime.notification("AXSelectedTextChanged")}
            case "terminal":EventStreamTreeTransactions.$current.withValue(lifetime.transaction()) {lifetime.notification("AXValueChanged")}
            default:lifetime.notification("AXFocusedWindowChanged")
            }
            await drain();weak let weakOwner=owner;let before=outputs.count;owner=nil
            check("\(kind) delay retains full native recorder root",weakOwner != nil && lifetime.clock.pending.count==1)
            lifetime.clock.finishAll();await drain()
            check("\(kind) completion emits and releases native recorder root",weakOwner==nil && outputs.count==before+1)
        }
        let cancelled=Fixture();cancelled.frontmostPresent=false
        var cancelledOwner:EventStreamNativeRecorder?=cancelled.make();var cancelledRecords:[EventStreamRecord]=[]
        cancelledOwner!.onRecordStored={cancelledRecords.append($0)};try cancelledOwner!.start();cancelled.key("z",code:0);await drain()
        cancelledOwner!.stop(emitSessionEnded:false);let countAfterStop=cancelledRecords.count
        weak let cancelledWeak=cancelledOwner;cancelledOwner=nil
        check("cancelled pending task retains root until it actually unwinds",cancelledWeak != nil)
        cancelled.clock.finishAll();await drain()
        check("cancelled task releases root without stale output",cancelledWeak==nil && cancelledRecords.count==countAfterStop && cancelledRecords.last?.kind == .keyboardTextInput)
        let restarted=Fixture();restarted.frontmostPresent=false
        let restartedOwner=restarted.make();var restartedRecords:[EventStreamRecord]=[];restartedOwner.onRecordStored={restartedRecords.append($0)}
        try restartedOwner.start();restarted.key();await drain();restartedOwner.stop(emitSessionEnded:false);try restartedOwner.start()
        restarted.clock.finishAll();await drain()
        check("native interaction keeps original identity across rapid restart",restartedRecords.map(\.id)==[1,3,2] && restartedRecords.map(\.kind)==[.sessionStarted,.sessionStarted,.keyboardShortcut])
        restartedOwner.stop(emitSessionEnded:false)
        check("native producer fixtures restore outer transaction",EventStreamTreeTransactions.current==nil)
        print("\(checks) checks")
    }
}
