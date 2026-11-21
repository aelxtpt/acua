import Foundation
import ApplicationServices

@MainActor private final class Sleeper {
    var delays:[Duration]=[],pending:[Int:CheckedContinuation<Void,Error>]=[:]
    func sleep(_ delay:Duration) async throws {
        let id=delays.count;delays.append(delay)
        try await withCheckedThrowingContinuation {pending[id]=$0}
    }
    func finish(_ id:Int,error:Error?=nil) {
        guard let continuation=pending.removeValue(forKey:id) else {return}
        if let error {continuation.resume(throwing:error)} else {continuation.resume()}
    }
}

@main enum Tests {
    @MainActor static func main() async {
        var checks=0
        func check(_ label:String,_ value:Bool) {precondition(value,"FAIL: \(label)");checks += 1;print("PASS: \(label)")}
        func drain() async {for _ in 0..<30 {await Task.yield()}}
        func identity(_ id:Int,_ date:Date=Date(timeIntervalSince1970:9))->EventStreamRecordIdentity {.init(id:id,timestamp:date)}
        let date=Date(timeIntervalSince1970:123),clock=Sleeper()
        var recording=false,trace:[String]=[],app:String?="Observer App",allow=false,sequence=0
        var layouts:[EventStreamRecordIdentity]=[],selected:[EventStreamPendingSelectionRecord]=[],terminals:[EventStreamPendingTerminalRecord<Int>]=[]
        var returnSelection=true,returnTerminal=true
        let dispatcher=EventStreamRecorderNotificationDispatcher<Int,String>(backend:.init(isRecording:{trace.append("recording");return recording},
            runningApplication:{trace.append("app:\($0)");return app},nextIdentity:{stamp in trace.append("identity");sequence += 1;return identity(sequence,stamp)},
            scheduleLayout:{trace.append("layout");layouts.append($0)},makeSelection:{element,name in
                trace.append("selection:\(element):\(name)");guard returnSelection else {return nil}
                return .init(key:"key",notification:name,record:.init(id:80,timestamp:date,kind:.selectionChanged))
            },enqueueSelection:{trace.append("enqueue");selected.append($0)},makeTerminal:{element,pid,bundle in
                trace.append("terminal:\(element):\(pid):\(bundle ?? "nil")");guard returnTerminal else {return nil}
                return .init(identity:identity(90),target:.init(role:"AXTextArea"),element:element,app:nil,window:nil)
            },storeTerminal:{trace.append("store");terminals.append($0)}))
        func receive(_ name:String,pid:Int32=41,bundle:String?="old.observer") {dispatcher.receive(element:5,notification:name,processIdentifier:pid,bundleIdentifier:bundle,timestamp:date)}
        receive("AXValueChanged")
        check("inactive notification exits before application and source reads",trace==["recording"] && sequence==0)
        recording=true;trace=[];dispatcher.shouldCaptureApplication={app in trace.append("policy:\(app)");return allow}
        receive("AXFocusedWindowChanged")
        check("denied live application suppresses every notification branch",trace==["recording","app:41","policy:Observer App"] && layouts.isEmpty && sequence==0)
        allow=true;trace=[];receive("AXFocusedWindowChanged")
        check("focused window uses callback timestamp for allocated identity",layouts==[identity(1,date)] && sequence==1)
        check("focused window schedules capture without element snapshot routes",trace==["recording","app:41","policy:Observer App","identity","layout"] && selected.isEmpty && terminals.isEmpty)
        trace=[];receive("AXValueChanged")
        check("value change forwards captured observer PID bundle and reference",trace==["recording","app:41","policy:Observer App","terminal:5:41:old.observer","store"] && terminals.count==1)
        check("terminal dispatcher does not preallocate layout identity",sequence==1 && layouts.count==1 && selected.isEmpty)
        returnTerminal=false;trace=[];receive("AXValueChanged")
        check("ineligible terminal does not store or fall through to selection",trace.last=="terminal:5:41:old.observer" && terminals.count==1 && selected.isEmpty)
        trace=[];receive("AXSelectedTextChanged")
        check("selection forwards raw notification and captured element",trace.suffix(2)==["selection:5:AXSelectedTextChanged","enqueue"] && selected.last?.notification=="AXSelectedTextChanged")
        check("selection retains builder identity independently of callback date allocation",selected.last?.record.id==80 && sequence==1)
        returnSelection=false;trace=[];receive("unrelated")
        check("unknown notifications delegate classification without enqueue",trace.last=="selection:5:unrelated" && selected.count==1)
        app=nil;allow=false;returnSelection=true;trace=[];receive("AXSelectedRowsChanged",pid:-9,bundle:nil)
        check("missing running app bypasses application policy",trace==["recording","app:-9","selection:5:AXSelectedRowsChanged","enqueue"])
        check("selection has no added positive or current observer PID gate",selected.count==2 && selected.last?.notification=="AXSelectedRowsChanged")
        returnTerminal=true;trace=[];receive("AXValueChanged",pid:7,bundle:nil)
        check("missing app forwards an absent bundle to terminal eligibility",trace==["recording","app:7","terminal:5:7:nil","store"])
        app="New Application";dispatcher.shouldCaptureApplication=nil;trace=[];receive("AXFocusedWindowChanged",pid:99)
        check("absent policy defaults true for available application",trace==["recording","app:99","identity","layout"] && layouts.last==identity(2,date))

        var captures:[EventStreamRecordIdentity]=[]
        let layout=EventStreamLayoutNotificationTask(isRecording:{recording},sleep:{try await clock.sleep($0)},capture:{captures.append($0)})
        layout.schedule(identity(10,date));await drain()
        check("layout capture schedules250 millisecond delay",clock.delays==[.milliseconds(250)] && layout.hasScheduledTask && captures.isEmpty)
        layout.schedule(identity(11,date));await drain();clock.finish(0);await drain()
        check("new focused window cancels old delay without capture",captures.isEmpty && clock.delays.count==2)
        clock.finish(1);await drain()
        check("latest layout delay passes exact captured identity",captures==[identity(11,date)])
        check("completed layout task remains in slot until cleanup",layout.hasScheduledTask)
        layout.schedule(identity(12));await drain();recording=false;clock.finish(2);await drain()
        check("inactive layout timer skips capture",captures.count==1)
        recording=true;enum Failure:Error {case other}
        layout.schedule(identity(13));await drain();clock.finish(3,error:Failure.other);await drain()
        check("noncancellation layout sleep error still captures",captures.last?.id==13)
        layout.schedule(identity(14));await drain();layout.cancel()
        check("layout cleanup cancels and clears task slot",!layout.hasScheduledTask)
        clock.finish(4);await drain();check("late cancelled layout task cannot capture",captures.last?.id==13)
        layout.cancel();check("repeated layout cleanup is inert",!layout.hasScheduledTask && clock.pending.isEmpty)

        let composedClock=Sleeper()
        var composed:[EventStreamRecord]=[]
        let queue=EventStreamAXNotificationQueue(isRecording:{recording},sleep:{try await composedClock.sleep($0)},emit:{composed.append($0)})
        let terminal=EventStreamTerminalValueRecorder<Int>(nextIdentity:{identity(99)},refreshTarget:{.init(title:"refreshed \($0)")},isRecording:{recording},sleep:{try await composedClock.sleep($0)},emit:{composed.append($0)})
        let composedLayout=EventStreamLayoutNotificationTask(isRecording:{recording},sleep:{try await composedClock.sleep($0)},capture:{composed.append(.init(id:$0.id,timestamp:$0.timestamp,kind:.windowChanged))})
        let integrated=EventStreamRecorderNotificationDispatcher<Int,String>(backend:.init(isRecording:{recording},runningApplication:{_ in nil},nextIdentity:{identity(110,$0)},scheduleLayout:composedLayout.schedule,
            makeSelection:{_,name in .init(key:"rows",notification:name,record:.init(id:101,timestamp:date,kind:.selectionChanged))},
            enqueueSelection:{queue.enqueue($0.record,key:$0.key,notification:$0.notification)},
            makeTerminal:{element,_,_ in .init(identity:identity(102),target:.init(title:"cached"),element:element,app:nil,window:nil)},storeTerminal:terminal.store))
        integrated.receive(element:8,notification:"AXSelectedTextChanged",processIdentifier:9,bundleIdentifier:nil,timestamp:date);await drain()
        integrated.receive(element:8,notification:"AXValueChanged",processIdentifier:9,bundleIdentifier:nil,timestamp:date);await drain()
        integrated.receive(element:8,notification:"AXFocusedWindowChanged",processIdentifier:9,bundleIdentifier:nil,timestamp:date);await drain()
        check("composed selection terminal and layout maintain independent delays",composedClock.delays==[.milliseconds(500),.milliseconds(750),.milliseconds(250)] && composed.isEmpty)
        composedClock.finish(2);await drain();composedClock.finish(0);await drain();composedClock.finish(1);await drain()
        check("composed branches emit in timer order without sorting identities",composed.map(\.id)==[110,101,102] && composed.map(\.kind)==[.windowChanged,.selectionChanged,.terminalValueChanged])
        check("composed terminal target refresh survives dispatcher routing",composed.last?.keyboard?.target?.title=="refreshed 8")
        check("selection and terminal buffers clear independently of layout slot",queue.pendingCount==0 && !terminal.hasPendingRecord && composedLayout.hasScheduledTask)
        composedLayout.cancel();terminal.cancelPendingFlush();queue.cancelPendingRecords()
        // Native composition with actual snapshot constructors, controlled
        // TaskLocal data and invalid negative AX references. No external UI.
        let nativeClock=Sleeper(),root=AXUIElementCreateApplication(-64000),window=AXUIElementCreateApplication(-64001)
        var nativeSequence=0,nativeEvents:[EventStreamRecord]=[]
        func next(_ stamp:Date=Date(timeIntervalSince1970:9))->EventStreamRecordIdentity {nativeSequence += 1;return identity(nativeSequence,stamp)}
        let sourceOwner=EventStreamNativeSelectionRecordFactory(nextIdentity:{next()})
        let terminalCapture=EventStreamNativeTerminalCapture(sourceOwner:sourceOwner,nextIdentity:{next()},io:.init(secureInputPID:{7},application:{.init(name:"Terminal",secureInput:true,processIdentifier:$0,bundleIdentifier:"com.apple.Terminal")}))
        let native=EventStreamNativeRecorderNotifications(sourceOwner:sourceOwner,terminalCapture:terminalCapture,nextIdentity:{next()},identityAt:{next($0)},isRecording:{recording},runningApplication:{_ in nil},sleep:{try await nativeClock.sleep($0)},captureWindowChanged:{nativeEvents.append(.init(id:$0.id,timestamp:$0.timestamp,kind:.windowChanged))},emit:{nativeEvents.append($0)})
        func transaction(title:String)->EventStreamNativeTreeTransaction {
            var range=CFRange(location:1,length:3)
            let values:[String:AnyObject]=["AXRole":"AXTextArea" as NSString,"AXTitle":title as NSString,"AXValue":"output" as NSString,
                "AXSubrole":NSNull(),"AXDescription":NSNull(),"AXPlaceholderValue":NSNull(),"AXIdentifier":"area" as NSString,
                "AXSelectedTextRange":AXValueCreate(.cfRange,&range)!,"AXSelectedText":"selected" as NSString,"AXWindow":window,"AXParent":NSNull()]
            return .init(root:root,snapshots:.init(attributeTable:[.init(element:root):values,
                .init(element:window):["AXRole":"AXWindow" as NSString,"AXTitle":"Captured Window" as NSString,"AXURL":URL(string:"https://captured.example")! as NSURL]],
                requestedAttributes:EventStreamSnapshotAttributes.common.union(["AXWindow","AXParent","AXSelectedTextRange","AXSelectedText"])),partialValues:[:],roleFrequency:[:])
        }
        var envelope:AXObserver?
        let status=AXObserverCreate(getpid(),{_,_,_,_ in},&envelope)
        guard status == .success,let envelope else {fatalError("cannot allocate local notification envelope")}
        func nativeReceive(_ name:String) {
            native.receive(.init(observer:envelope,element:root,notification:name,userInfo:[:]),processIdentifier:7,bundleIdentifier:"com.apple.Terminal",timestamp:date)
        }
        EventStreamTreeTransactions.$current.withValue(transaction(title:"Before")) {nativeReceive("AXSelectedTextChanged")};await drain()
        EventStreamTreeTransactions.$current.withValue(transaction(title:"Before")) {nativeReceive("AXValueChanged")};await drain()
        nativeReceive("AXFocusedWindowChanged");await drain()
        check("native dispatcher composes three real component delays",nativeClock.delays==[.milliseconds(500),.milliseconds(750),.milliseconds(250)] && nativeEvents.isEmpty && nativeSequence==3)
        EventStreamTreeTransactions.$current.withValue(transaction(title:"After")) {native.flushTerminal()}
        check("native dispatcher terminal flush reconstructs current target",nativeEvents.first?.id==2 && nativeEvents.first?.keyboard?.target?.title=="After")
        check("native dispatcher terminal retains captured app and window",nativeEvents.first?.app?.processIdentifier==7 && nativeEvents.first?.window?.title=="Captured Window")
        nativeClock.finish(2);await drain();nativeClock.finish(0);await drain();nativeClock.finish(1);await drain()
        check("native dispatcher preserves independent record identity order",nativeEvents.map(\.id)==[2,3,1] && nativeEvents.map(\.kind)==[.terminalValueChanged,.windowChanged,.selectionChanged])
        check("native focused-window identity retains entry timestamp",nativeEvents[1].timestamp==date && nativeEvents[0].timestamp==Date(timeIntervalSince1970:9))
        check("native selection queue retains captured selection and target",nativeEvents.last?.selection?.selectedText=="selected" && nativeEvents.last?.selection?.target?.title=="Before")
        native.cancelPendingTasks();native.clearTerminalBuffer()
        check("native dispatcher cleanup leaves no controlled delays",nativeClock.pending.isEmpty)
        check("native dispatcher restores outer TaskLocal transaction",EventStreamTreeTransactions.current==nil)
        EventStreamTreeTransactions.$current.withValue(transaction(title:"Owner already checked")) {nativeReceive("AXSelectedTextChanged")};await drain()
        recording=false;native.flushSelection()
        check("native selection flush after owner guard has no second active-state gate",nativeEvents.count==4 && nativeEvents.last?.id==4 && nativeEvents.last?.kind == .selectionChanged)
        nativeClock.finish(3);await drain()
        check("selection owner flush prevents later duplicate after state change",nativeEvents.count==4 && nativeClock.pending.isEmpty)
        native.cancelPendingTasks();recording=true
        print("\(checks) checks")
    }
}
