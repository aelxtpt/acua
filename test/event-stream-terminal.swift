import Foundation
import ApplicationServices

@MainActor private final class ControlledSleeper {
    var delays:[Duration]=[]
    var pending:[Int:CheckedContinuation<Void,Error>]=[:]
    func sleep(_ delay:Duration) async throws {
        let index=delays.count;delays.append(delay)
        try await withCheckedThrowingContinuation {pending[index]=$0}
    }
    func finish(_ index:Int,error:Error?=nil) {
        guard let value=pending.removeValue(forKey:index) else {return}
        if let error {value.resume(throwing:error)} else {value.resume()}
    }
}

@main enum Tests {
    @MainActor static func main() async {
        var checks=0
        func check(_ label:String,_ condition:Bool) {
            precondition(condition,"FAIL: \(label)");checks += 1;print("PASS: \(label)")
        }
        func drain() async {for _ in 0..<30 {await Task.yield()}}
        func identity(_ id:Int)->EventStreamRecordIdentity {
            .init(id:id,timestamp:Date(timeIntervalSince1970:Double(id)))
        }
        func target(_ title:String)->EventStreamAXElement {
            .init(role:"AXTextArea",title:title,value:"value \(title)")
        }
        let expected=["com.apple.Terminal","com.googlecode.iterm2","org.alacritty","dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty","co.zeit.hyper","com.github.wez.wezterm","org.tabby",
            "com.mitchellh.ghostty","com.raphaelamorim.rio","dev.commandline.waveterm"]
        check("terminal membership preserves its 11 values and order",EventStreamTerminalBundleIdentifiers.all==expected)
        for bundle in expected {
            check("terminal observation adds value change for \(bundle)",EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:bundle)==EventStreamRecorderAXObservationPolicy.baseNotifications+["AXValueChanged"])
        }
        check("nonterminal and absent bundle keep seven notifications",EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:"example.term")==EventStreamRecorderAXObservationPolicy.baseNotifications && EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:nil).count==7)
        check("terminal matching is case sensitive without trimming",EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:"COM.APPLE.TERMINAL").count==7 && EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:" com.apple.Terminal").count==7)

        var trace:[String]=[],secure:Int?=12,role:String?="AXTextArea",sequence=0
        var app:EventStreamApp? = .init(name:"Captured App",secureInput:true,processIdentifier:12,bundleIdentifier:"com.apple.Terminal")
        var window:EventStreamWindow? = .init(title:"Captured Window",url:"https://captured.example",windowID:50)
        let capture=EventStreamTerminalCapture<Int,Int>(backend:.init(wrap:{trace.append("wrap:\($0)");return $0},
            secureInputPID:{trace.append("secure");return secure},role:{trace.append("role:\($0)");return role},
            nextIdentity:{trace.append("identity");sequence += 1;return identity(sequence)},
            target:{trace.append("target:\($0)");return target("cached \($0)")},
            application:{trace.append("app:\($0)");return app},window:{trace.append("window:\($0)");return window}))
        func make(_ bundle:String?="com.apple.Terminal",pid:Int32=12)->EventStreamPendingTerminalRecord<Int>? {
            capture.make(element:42,processIdentifier:pid,bundleIdentifier:bundle)
        }
        check("unknown terminal is rejected after eager wrapping",make("other")==nil && trace==["wrap:42"])
        trace=[];check("absent terminal is rejected after eager wrapping",make(nil)==nil && trace==["wrap:42"])
        trace=[];check("nonpositive captured PID skips session and role",make(pid:0)==nil && trace==["wrap:42"])
        trace=[];check("negative captured PID skips session and role",make(pid:-12)==nil && trace==["wrap:42"])
        secure=nil;trace=[];check("missing secure input owner rejects before role",make()==nil && trace==["wrap:42","secure"])
        secure=13;trace=[];check("different secure input owner rejects before role",make()==nil && trace==["wrap:42","secure"])
        secure=12;role="AXTextField";trace=[];check("text field is not accepted as terminal area",make()==nil && trace==["wrap:42","secure","role:42"])
        role=nil;trace=[];check("missing role rejects without consuming identity",make()==nil && sequence==0)
        role="AXTextArea";trace=[]
        let first=make()!
        check("eligible branch allocates identity before target app window",trace==["wrap:42","secure","role:42","identity","target:42","app:12","window:42"])
        check("eligible pending record retains captured identity context and raw reference",first.identity==identity(1) && first.target==target("cached 42") && first.element==42 && first.app==app && first.window==window)
        app=nil;window=nil
        check("missing app and window do not suppress eligible terminal record",make()?.identity==identity(2))
        check("captured observer PID is used independently of wrapped reference",sequence==2)

        let clock=ControlledSleeper()
        var recording=true,emitted:[EventStreamRecord]=[],refreshes:[Int]=[]
        var recorder:EventStreamTerminalValueRecorder<Int>!
        var duringEmit:((EventStreamRecord)->Void)?,duringIdentity:(()->Void)?,duringRefresh:(()->Void)?
        recorder = .init(nextIdentity:{duringIdentity?();sequence += 1;return identity(sequence)},
            refreshTarget:{refreshes.append($0);duringRefresh?();return target("fresh \($0)")},
            isRecording:{recording},sleep:{try await clock.sleep($0)},emit:{emitted.append($0);duringEmit?($0)})
        func pending(_ id:Int?,element:Int?=42)->EventStreamPendingTerminalRecord<Int> {
            .init(identity:id.map(identity),target:target("cached \(id ?? -1)"),element:element,
                app:.init(name:"App \(id ?? -1)",secureInput:true,processIdentifier:12),
                window:.init(title:"Window \(id ?? -1)",windowID:50))
        }
        recorder.flush()
        check("empty flush allocates no identity and emits nothing",sequence==2 && emitted.isEmpty && !recorder.hasPendingRecord)
        recorder.store(pending(3));await drain()
        check("terminal schedules750 milliseconds",clock.delays==[.milliseconds(750)] && recorder.hasPendingRecord && recorder.hasScheduledFlush)
        recorder.store(pending(4,element:43));await drain()
        check("overwrite replaces entire payload without early emission",clock.delays.count==2 && emitted.isEmpty && refreshes.isEmpty)
        clock.finish(0);await drain()
        check("cancelled older task cannot consume latest buffer",emitted.isEmpty && recorder.hasPendingRecord)
        duringRefresh={check("target refresh occurs while pending buffer and timer still exist",recorder.hasPendingRecord && recorder.hasScheduledFlush)}
        clock.finish(1);await drain();duringRefresh=nil
        check("flush refreshes latest retained element",refreshes==[43] && emitted.last?.keyboard?.target==target("fresh 43"))
        check("captured identity and timestamp survive debounce",emitted.last?.id==4 && emitted.last?.timestamp==identity(4).timestamp && sequence==2)
        check("latest captured app and window survive target refresh",emitted.last?.app==pending(4).app && emitted.last?.window==pending(4).window)
        let event=emitted.last!
        check("terminal event has target only keyboard payload",event.kind == .terminalValueChanged && event.keyboard?.text==nil && event.keyboard?.keyEquivalent==nil && event.keyboard?.modifiers==[])
        check("unrelated event payloads remain absent",event.mouse==nil && event.selection==nil && event.ax==nil && event.diagnostic==nil)
        check("successful flush clears buffer and timer",!recorder.hasPendingRecord && !recorder.hasScheduledFlush)
        recorder.flush();check("repeated flush does not duplicate",emitted.count==1 && refreshes==[43])
        recorder.store(pending(5,element:nil));await drain();recorder.flush()
        check("missing retained reference keeps cached descriptor",emitted.last?.keyboard?.target==target("cached 5") && refreshes==[43])
        clock.finish(2);await drain();check("explicit flush prevents delayed duplicate",emitted.count==2)
        recorder.store(pending(nil,element:nil));await drain()
        duringIdentity={check("fallback identity is allocated after buffer and timer reset",!recorder.hasPendingRecord && !recorder.hasScheduledFlush)}
        recorder.flush();duringIdentity=nil
        check("missing captured identity allocates exactly one new identity",emitted.last?.id==3 && emitted.last?.timestamp==identity(3).timestamp && sequence==3)
        clock.finish(3);await drain()
        recorder.store(pending(6));await drain();recording=false;clock.finish(4);await drain()
        check("inactive timer does not flush or clear buffer",emitted.count==3 && recorder.hasPendingRecord)
        recorder.flush()
        check("terminal explicit flush has no independent recording guard",emitted.last?.id==6 && !recorder.hasPendingRecord && !recorder.hasScheduledFlush)
        recording=true
        enum Failure:Error {case other}
        recorder.store(pending(7));await drain();clock.finish(5,error:Failure.other);await drain()
        check("noncancellation sleep error still flushes",emitted.last?.id==7 && !recorder.hasPendingRecord)
        recorder.store(pending(8));await drain();recorder.cancelPendingFlush()
        check("timer cleanup preserves pending terminal buffer",recorder.hasPendingRecord && !recorder.hasScheduledFlush)
        clock.finish(6);await drain();check("cancelled timer stays inert",emitted.last?.id==7 && recorder.hasPendingRecord)
        recorder.flush();check("cancelled timer buffer can be explicitly flushed",emitted.last?.id==8)
        recorder.store(pending(9));await drain();recorder.clearBuffer()
        check("buffer reset does not cancel independent timer",!recorder.hasPendingRecord && recorder.hasScheduledFlush)
        clock.finish(7);await drain()
        check("empty timer flush emits nothing and leaves timer slot",emitted.last?.id==8 && recorder.hasScheduledFlush)
        recorder.cancelPendingFlush();recorder.cancelPendingFlush()
        check("repeated timer cleanup is inert",!recorder.hasScheduledFlush && !recorder.hasPendingRecord)
        recorder.store(pending(10));await drain()
        duringEmit={event in
            if event.id==10 {
                check("emission sees cleared terminal buffer and timer",!recorder.hasPendingRecord && !recorder.hasScheduledFlush)
                recorder.store(pending(11,element:99))
            }
        }
        recorder.flush();await drain();duringEmit=nil
        check("reentrant emission preserves new pending payload",recorder.hasPendingRecord && recorder.hasScheduledFlush && emitted.last?.id==10)
        clock.finish(8);await drain();check("old task cannot consume reentrant payload",emitted.last?.id==10 && recorder.hasPendingRecord)
        clock.finish(9);await drain();check("new reentrant timer refreshes and emits its own payload",emitted.last?.id==11 && emitted.last?.keyboard?.target==target("fresh 99") && !recorder.hasPendingRecord)
        check("all controlled timers have been released",clock.pending.isEmpty)
        recorder=nil

        let lifetimeClock=ControlledSleeper()
        var lifetimeEvents:[Int]=[]
        var owner:EventStreamTerminalValueRecorder<Int>? = .init(nextIdentity:{identity(100)},refreshTarget:{target("\($0)")},isRecording:{true},sleep:{try await lifetimeClock.sleep($0)},emit:{lifetimeEvents.append($0.id)})
        weak let weakOwner=owner
        owner!.store(pending(20));await drain();owner=nil
        check("scheduled terminal task retains its owner",weakOwner != nil)
        lifetimeClock.finish(0);await drain()
        check("completed timer releases retained owner after emission",weakOwner==nil && lifetimeEvents==[20])
        // The native binder below uses actual snapshot construction with a
        // controlled TaskLocal table. Invalid negative references cannot point
        // at another app; the observer PID is deliberately independent.
        let root=AXUIElementCreateApplication(-61000),nativeWindow=AXUIElementCreateApplication(-61001)
        var nativeSequence=200,nativeAppPIDs:[Int32]=[],nativeRoleReads=0
        var nativeSecure:Int?=31
        var nativeIO=EventStreamNativeSelectionRecordIO.native
        nativeIO.attribute={element,name in
            precondition(CFEqual(element,root) && name=="AXRole")
            nativeRoleReads += 1;return (.success,"AXTextArea" as NSString)
        }
        let reader=EventStreamNativeSelectionRecordBackend(io:nativeIO)
        let sourceOwner=EventStreamNativeSelectionRecordFactory(nextIdentity:{nativeSequence += 1;return identity(nativeSequence)},selectionBackend:reader)
        let native=EventStreamNativeTerminalCapture(sourceOwner:sourceOwner,nextIdentity:{nativeSequence += 1;return identity(nativeSequence)},
            io:.init(secureInputPID:{nativeSecure},application:{pid in
                nativeAppPIDs.append(pid);return .init(name:"Terminal App",secureInput:true,processIdentifier:pid,bundleIdentifier:"terminal.metadata")
            }),reader:reader)
        func transaction(title:String,role:AnyObject="AXTextArea" as NSString,windowTitle:String="Window Before")->EventStreamNativeTreeTransaction {
            let values:[String:AnyObject]=["AXRole":role,"AXTitle":title as NSString,"AXValue":"terminal output" as NSString,
                "AXSubrole":NSNull(),"AXDescription":NSNull(),"AXPlaceholderValue":NSNull(),"AXIdentifier":"terminal-area" as NSString,
                "AXParent":NSNull(),"AXWindow":nativeWindow]
            let table:[EventStreamSnapshotAXIdentity:[String:AnyObject]]=[.init(element:root):values,
                .init(element:nativeWindow):["AXRole":"AXWindow" as NSString,"AXTitle":windowTitle as NSString,"AXURL":URL(string:"https://terminal.example/context")! as NSURL]]
            return .init(root:root,snapshots:.init(attributeTable:table,requestedAttributes:EventStreamSnapshotAttributes.common.union(["AXWindow","AXParent"])),partialValues:[:],roleFrequency:[:])
        }
        let captured=EventStreamTreeTransactions.$current.withValue(transaction(title:"  Before  ")) {
            native.make(element:root,processIdentifier:31,bundleIdentifier:"com.apple.Terminal")!
        }
        check("native binder reads terminal role from captured snapshot",nativeRoleReads==0 && captured.target.role=="AXTextArea")
        check("native binder preserves raw title and captured output",captured.target.title=="  Before  " && captured.target.value=="terminal output")
        check("native binder app helper uses captured observer PID",nativeAppPIDs==[31] && captured.app?.processIdentifier==31)
        check("native binder resolves containing window through shared snapshot owner",captured.window?.title=="Window Before" && captured.window?.url=="https://terminal.example/context")
        check("native binder allocates caller identity and retains AX reference",captured.identity==identity(201) && CFEqual(captured.element!,root))
        let fresh=EventStreamTreeTransactions.$current.withValue(transaction(title:"  After  ",windowTitle:"Window After")) {native.refreshTarget(root)}
        check("native flush reconstruction reads a new snapshot",fresh.title=="  After  " && fresh.identifier=="terminal-area")
        check("target refresh leaves captured app window and identity intact",captured.window?.title=="Window Before" && captured.app?.processIdentifier==31 && nativeSequence==201)
        let integrationClock=ControlledSleeper()
        var integrated:[EventStreamRecord]=[]
        let integratedRecorder=EventStreamTerminalValueRecorder<AXUIElement>(nextIdentity:{nativeSequence += 1;return identity(nativeSequence)},refreshTarget:native.refreshTarget,isRecording:{true},sleep:{try await integrationClock.sleep($0)},emit:{integrated.append($0)})
        integratedRecorder.store(captured);await drain()
        EventStreamTreeTransactions.$current.withValue(transaction(title:"Fresh output target",windowTitle:"Changed Window")) {integratedRecorder.flush()}
        check("native composition refreshes target from flush transaction",integrated.first?.keyboard?.target?.title=="Fresh output target")
        check("native composition preserves entry window and application",integrated.first?.window==captured.window && integrated.first?.app==captured.app)
        check("native composition reuses identity without sequence increment",integrated.first?.id==201 && nativeSequence==201)
        integrationClock.finish(0);await drain()
        check("native composition cancels timer after explicit flush",integrated.count==1 && !integratedRecorder.hasPendingRecord && !integratedRecorder.hasScheduledFlush)
        let fallback=EventStreamTreeTransactions.$current.withValue(transaction(title:"Fallback",role:NSNumber(value:5))) {
            native.make(element:root,processIdentifier:31,bundleIdentifier:"com.apple.Terminal")
        }
        check("malformed cached role falls back to typed native string",fallback != nil && nativeRoleReads==1 && nativeSequence==202)
        nativeSecure=32
        let denied=EventStreamTreeTransactions.$current.withValue(transaction(title:"Denied")) {native.make(element:root,processIdentifier:31,bundleIdentifier:"com.apple.Terminal")}
        check("native secure PID mismatch skips record metadata and identity",denied==nil && nativeSequence==202 && nativeAppPIDs==[31,31])
        let cachedURL=URL(string:"https://shared.example")!;sourceOwner.context.resolver.recordCapturedURL(cachedURL,for:77)
        check("native terminal and selection paths retain same URL cache owner",sourceOwner.context.resolver.windowURLs[77]==cachedURL)
        check("native binding restores caller transaction",EventStreamTreeTransactions.current==nil)
        print("\(checks) checks")
    }
}
