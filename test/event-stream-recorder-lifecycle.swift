import Foundation
import CoreGraphics
import Observation

@MainActor private final class Sleeper {
    var waits:[Duration]=[],pending:[Int:CheckedContinuation<Void,Error>]=[:]
    func sleep(_ duration:Duration) async throws {
        let id=waits.count;waits.append(duration)
        try await withCheckedThrowingContinuation {pending[id]=$0}
    }
    func finish(_ id:Int,error:Error?=nil) {
        guard let c=pending.removeValue(forKey:id) else {return}
        if let error {c.resume(throwing:error)} else {c.resume()}
    }
}
private final class Owner {var values:[String]=[]}
private final class Revision {}
private final class Counter:@unchecked Sendable {
    private let lock=NSLock()
    private var stored=0
    var value:Int {lock.lock();defer{lock.unlock()};return stored}
    func increment() {lock.lock();stored += 1;lock.unlock()}
}

@main enum Tests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ label:String,_ value:Bool) {precondition(value,"FAIL: \(label)");checks += 1;print("PASS: \(label)")}
        func drain() async {for _ in 0..<40 {await Task.yield()}}
        typealias Lifecycle=EventStreamRecorderLifecycle<String>
        var trace:[String]=[],tick=0,app:String?="App",records:[EventStreamRecord]=[],suppressed:[EventStreamRecord]=[]
        var recorder:Lifecycle!
        var currentPolicy:((String)->Bool)?
        let backend=Lifecycle.Backend(now:{tick += 1;trace.append("now:\(tick)");return Date(timeIntervalSince1970:Double(tick))},
            clearPreviousRevision:{trace.append("revision")},clearPreviousWindowID:{trace.append("windowID")},clearURLs:{trace.append("URLs")},
            clearMouseDown:{trace.append("mouse")},clearTextBuffer:{trace.append("textBuffer")},clearTerminalBuffer:{trace.append("terminalBuffer")},
            clearSelectionRecords:{trace.append("selectionRecords")},clearSelectionTaskOwners:{trace.append("selectionTasks")},
            installInputTap:{check("recording is true before input monitor setup",recorder.isRecording);trace.append("tap")},subscribeFrontmost:{trace.append("subscribe")},
            currentApplication:{trace.append("currentApp");return app},refreshApplication:{value,date in trace.append("refresh:\(value):\(Int(date.timeIntervalSince1970))")},
            flushText:{trace.append("flushText")},flushTerminal:{trace.append("flushTerminal")},flushSelectionAfterRecordingGuard:{trace.append("flushSelection")},
            stopInputTap:{trace.append("stopTap")},unsubscribeFrontmost:{trace.append("unsubscribe")},stopAXObserver:{trace.append("stopAX")},
            cancelDelayedTasks:{trace.append("cancelTasks")},clearCurrentApplication:{trace.append("clearPID")},capturePolicyChanged:{currentPolicy=$0;trace.append("policy")})
        recorder=Lifecycle(backend:backend)
        check("new recorder is inactive with zero sequence",!recorder.isRecording && recorder.sequence==0)
        recorder.flushPendingRecords();recorder.stop(emitSessionEnded:true);recorder.refreshCurrentApplication()
        check("inactive flush stop and refresh have no effects",trace.isEmpty && tick==0)
        recorder.onRecordStored={record in records.append(record);trace.append("record:\(record.kind.rawValue)")}
        recorder.onSuppressedRecordStored={suppressed.append($0)}
        try recorder.start()
        check("start resets recorder fields before installing sources and initial boundary",trace==["revision","windowID","URLs","mouse","textBuffer","terminalBuffer","selectionRecords","selectionTasks","tap","subscribe","now:1","record:session.started","currentApp","now:2","refresh:App:2"])
        check("initial boundary consumes first identity with current timestamp",records.first?.id==1 && records.first?.timestamp==Date(timeIntervalSince1970:1) && recorder.sequence==1)
        check("boundary contains no app window or input/tree payloads",records[0].app==nil && records[0].window==nil && records[0].mouse==nil && records[0].keyboard==nil && records[0].selection==nil && records[0].ax==nil && records[0].diagnostic==nil)
        trace=[];try recorder.start();check("repeated start leaves active recorder untouched",trace.isEmpty && recorder.sequence==1)
        recorder.shouldCaptureApplication={$0=="Allowed"}
        check("capture policy change forwards without querying or refreshing app",trace==["policy"] && currentPolicy?("Allowed")==true && currentPolicy?("Other")==false)
        recorder.shouldCaptureApplication=nil;check("cleared policy is forwarded",currentPolicy==nil)
        trace=[];recorder.flushPendingRecords()
        check("flush preserves text terminal then selection order",trace==["flushText","flushTerminal","flushSelection"])
        trace=[];recorder.stop(emitSessionEnded:true)
        check("stop flushes and emits boundary before source teardown",trace==["flushText","flushTerminal","flushSelection","now:3","record:session.ended","stopTap","unsubscribe","stopAX","cancelTasks","clearPID","windowID","URLs","mouse"])
        check("stop leaves sequence advanced and recording false",!recorder.isRecording && recorder.sequence==2 && records.last?.id==2)
        check("stop does not clear revision text or terminal buffers",!trace.contains("revision") && !trace.contains("textBuffer") && !trace.contains("terminalBuffer"))
        trace=[];recorder.stop(emitSessionEnded:true);check("repeated stop is inert",trace.isEmpty && records.count==2)
        let inactiveBoundary=recorder.makeSessionBoundaryRecord(kind:.sessionStarted)
        check("public boundary construction works while inactive without emission",inactiveBoundary.id==3 && recorder.sequence==3 && records.count==2)
        app=nil;trace=[];try recorder.start()
        check("restart continues shared sequence without resetting it",records.last?.id==4 && recorder.sequence==4)
        check("missing current app avoids another timestamp and transition",trace.suffix(3)==["now:5","record:session.started","currentApp"] && tick==5)
        trace=[];recorder.stop(emitSessionEnded:false)
        check("stop false omits session ended boundary and clock read",records.count==3 && recorder.sequence==4 && !trace.contains(where:{$0.hasPrefix("now:")}))
        let late=EventStreamRecord(id:400,timestamp:Date(),kind:.windowChanged)
        recorder.store(.init(record:late,isSuppressed:false));recorder.store(.init(record:late,isSuppressed:true))
        check("async completion routes ordinary and suppressed independently after stop",records.last==late && suppressed==[late])
        recorder.onSuppressedRecordStored=nil;let beforeSuppression=records.count
        recorder.store(.init(record:late,isSuppressed:true));check("missing suppressed sink does not fall back to ordinary",records.count==beforeSuppression)
        recorder.onRecordStored=nil;let beforeSilent=recorder.sequence
        try recorder.start();recorder.stop(emitSessionEnded:true)
        check("boundaries still allocate identities with no record callback",recorder.sequence==beforeSilent+2)
        // A boundary consumer can stop synchronously; the recorder still queries
        // the tracker afterward, then application transition applies its gate.
        trace=[];app="Reentrant"
        recorder.onRecordStored={record in
            trace.append("record:\(record.kind.rawValue)")
            if record.kind == .sessionStarted {recorder.stop(emitSessionEnded:false)}
        }
        try recorder.start()
        check("boundary callback can stop without a hidden stopping epoch",!recorder.isRecording && trace.contains("stopTap"))
        check("initial handling queries tracker after reentrant boundary stop",trace.suffix(3)==["currentApp","now:\(tick)","refresh:Reentrant:\(tick)"])
        recorder=nil

        // Real coordinator + lifecycle producer, including independently
        // allocated subscriber boundaries and the union capture policy.
        recorder=Lifecycle(backend:backend);app=nil;trace=[]
        let coordinator=EventStreamCaptureCoordinator(recorder:recorder!)
        var sinkA:[EventStreamRecord]=[],sinkB:[EventStreamRecord]=[],suppressedB:[EventStreamRecord]=[]
        let subscriptionA=try coordinator.subscribe(shouldCapture:{$0=="A"},onRecord:{sinkA.append($0)})
        check("coordinator starts actual lifecycle producer and delivers first boundary",recorder.isRecording && sinkA.map(\.id)==[1] && sinkA.first?.kind == .sessionStarted)
        let subscriptionB=try coordinator.subscribe(shouldCapture:{$0=="B"},onRecord:{sinkB.append($0)},onSuppressedRecord:{suppressedB.append($0)})
        check("joining subscriber gets its own boundary without duplicate broadcast",sinkA.map(\.id)==[1] && sinkB.map(\.id)==[2])
        check("coordinator capture policy combines active subscribers",currentPolicy?("A")==true && currentPolicy?("B")==true && currentPolicy?("Other")==false)
        recorder.store(.init(record:late,isSuppressed:true))
        check("coordinator suppressed channel reaches only interested sink",suppressedB==[late] && sinkA.count==1 && sinkB.count==1)
        coordinator.unsubscribe(subscriptionA)
        check("removing first subscriber emits only its boundary and keeps recording",sinkA.map(\.id)==[1,3] && sinkA.last?.kind == .sessionEnded && sinkB.map(\.id)==[2] && recorder.isRecording)
        check("remaining subscriber changes aggregate policy",currentPolicy?("A")==false && currentPolicy?("B")==true)
        coordinator.unsubscribe(subscriptionB)
        check("final unsubscribe stops producer without extra ended boundary",sinkB.map(\.id)==[2,4] && sinkB.last?.kind == .sessionEnded && !recorder.isRecording && recorder.sequence==4 && currentPolicy==nil)
        coordinator.unsubscribe(subscriptionB)
        check("repeated coordinator unsubscribe is inert",recorder.sequence==4 && coordinator.subscriptionCount==0)
        recorder=nil

        // Ordered subscription snapshot; callbacks run outside the lock.
        let observers=EventStreamFrontmostObservers<Int>()
        var calls:[String]=[],second:EventStreamFrontmostObservers<Int>.Token?,third:EventStreamFrontmostObservers<Int>.Token?
        let first=observers.add {value in
            calls.append("A\(value)")
            if value==1 {observers.remove(second!);third=observers.add {calls.append("C\($0)")}}
        }
        second=observers.add {calls.append("B\($0)")}
        check("adding observer does not immediately publish",calls.isEmpty)
        observers.publish(1);check("observer snapshot preserves removed subscriber for current delivery",calls==["A1","B1"])
        observers.publish(2);check("observer additions and removal affect next delivery in order",calls==["A1","B1","A2","C2"])
        observers.remove(first);observers.remove(first);observers.remove(third!)
        let foreign=EventStreamFrontmostObservers<Int>().add {_ in}
        observers.remove(foreign);let beforeRemoved=calls.count;observers.publish(3)
        check("removed or foreign tokens are safely absent by identity",calls.count==beforeRemoved)
        var retainedOwner:Owner?=Owner();weak let weakRetainedOwner=retainedOwner
        var token:EventStreamFrontmostObservers<Int>.Token?=observers.add {[captured=retainedOwner!] _ in captured.values.append("held")}
        weak let weakToken=token;token=nil;retainedOwner=nil
        check("tracker retains token and its handler capture until removal",weakToken != nil && weakRetainedOwner != nil)
        observers.remove(weakToken!)
        check("token removal releases handler and captures",weakToken==nil && weakRetainedOwner==nil)
        let state=EventStreamFrontmostTrackerState<Int>(isCurrent:{$0==99},isTerminated:{$0==5},equal:==,fallback:{8})
        check("state returns changed candidate for exact notification delivery",state.updateValue(5)==5 && state.current()==8)
        check("unchanged candidate produces no observer notification",state.updateValue(5)==nil)
        let deliveryOwner=Owner();var deliveryClock=0
        let delivery=EventStreamRecorderFrontmostDelivery<Owner,String>(owner:deliveryOwner,now:{deliveryClock += 1;return Date(timeIntervalSince1970:Double(deliveryClock))}) {owner,value,date in
            MainActor.preconditionIsolated();owner.values.append("\(value):\(Int(date.timeIntervalSince1970))")
        }
        delivery.receive("App");check("frontmost entry captures timestamp before actor hop",deliveryClock==1 && deliveryOwner.values.isEmpty)
        await drain();check("frontmost callback delivers retained app and entry date on actor",deliveryOwner.values==["App:1"])
        var releasedOwner:Owner?=Owner();weak let weakReleased=releasedOwner
        var afterRelease=false
        let weakDelivery=EventStreamRecorderFrontmostDelivery<Owner,String>(owner:releasedOwner!,now:Date.init) {_,_,_ in afterRelease=true}
        weakDelivery.receive("Released");releasedOwner=nil
        check("frontmost queued delivery keeps recorder weak",weakReleased==nil)
        await drain();check("released recorder receives no queued frontmost callback",!afterRelease)

        var active=true,identityCount=0,textEvents:[EventStreamRecord]=[]
        let textClock=Sleeper()
        var text:EventStreamTextInputRecorder<Int>? = .init(nextIdentity:{identityCount += 1;return .init(id:identityCount,timestamp:Date())},refreshTarget:{_ in .init()},resolveContext:{_ in (nil,nil)},isRecording:{active},sleep:textClock.sleep,emit:{textEvents.append($0)})
        let target=EventStreamEventTarget(identity:.init())
        text!.append("error",target:target,captureTarget:{.init()});await drain();textClock.finish(0,error:CancellationError());await drain()
        check("thrown CancellationError without task cancellation still flushes text",textEvents.last?.keyboard?.text=="error")
        text!.append("preserved",target:target,captureTarget:{.init()});await drain();text!.cancelPendingFlush()
        check("text timer cancellation preserves buffer",text!.text=="preserved")
        textClock.finish(1);await drain();check("cancelled text timer remains inert",textEvents.count==1 && text!.text=="preserved")
        active=false;text!.flush();check("explicit text flush has no extra recording guard",textEvents.last?.keyboard?.text=="preserved")
        active=true;text!.append("clear",target:target,captureTarget:{.init()});await drain();text!.clearBuffer()
        let beforeClear=identityCount;textClock.finish(2);await drain()
        check("buffer clear leaves old timer harmless without allocating identity",textEvents.count==2 && identityCount==beforeClear)
        text!.append("retained",target:target,captureTarget:{.init()});await drain()
        weak let weakText=text;text=nil
        check("scheduled text task retains its recorder",weakText != nil)
        textClock.finish(3);await drain();check("text timer releases recorder after delivery",weakText==nil && textEvents.last?.keyboard?.text=="retained")

        let inputClock=Sleeper();var prepared:[EventStreamPreparedInteraction]=[]
        var builder:EventStreamInputRecordBuilder<Int>? = .init(nextIdentity:{identityCount += 1;return .init(id:identityCount,timestamp:Date())},isRecording:{active},fallbackProcessIdentifier:{nil},capturePermitted:{_ in true},keyboardTarget:{$0},resolveTarget:{.init(identity:$0)},endpointAt:{_,_ in nil},focusedTarget:{_ in .init()},refreshTarget:{_ in .init()},currentRole:{_ in nil},characterCount:{_ in nil},resolveTextContext:{_ in (nil,nil)},sleep:inputClock.sleep,emitText:{textEvents.append($0)},prepare:{prepared.append($0)})
        let key=EventStreamInputObservation(type:.keyDown,location:.zero,flags:[],target:.init(),clickCount:0,keyCode:53,characters:"",charactersIgnoringModifiers:"")
        builder!.receive(key);await drain();active=false
        builder!.clearMouseDown();builder!.cancelTextFlush();builder!.clearTextBuffer();active=true
        check("native stop/reset input ports preserve scheduled interaction",builder!.pendingInteractionCount==1)
        inputClock.finish(0);await drain();check("interaction survives rapid stop restart when active at deadline",prepared.count==1)
        builder!.receive(key);await drain();active=false;inputClock.finish(1);await drain()
        check("interaction that reaches deadline while inactive is dropped",prepared.count==1 && builder!.pendingInteractionCount==0)
        active=true;builder!.receive(key);await drain();inputClock.finish(2,error:CancellationError());await drain()
        check("uncancelled interaction runs after thrown sleep error",prepared.count==2 && prepared.last?.kind == .keyboardShortcut)
        builder!.receive(key);await drain();weak let weakBuilder=builder;builder=nil
        check("scheduled interaction retains its builder",weakBuilder != nil)
        inputClock.finish(3);await drain();check("interaction releases builder after completion",weakBuilder==nil && prepared.count==3 && inputClock.pending.isEmpty)

        weak var previous:Revision?
        var predecessorFlags:[Bool]=[]
        let capture=EventStreamAXCapture<Int,Revision>(resolveContext:{_ in 7},contextWindowID:{UInt32($0)},captureTree:{_,old in
            predecessorFlags.append(old != nil);let revision=Revision();previous=revision
            return .init(revision:revision,windowID:7,app:.init(name:"App",secureInput:false),window:.init(title:"Window",windowID:7))
        },render:{_,_,_,_ in "tree"})
        _=try await capture.capture(nil,preferDiff:true)
        check("capture retains prior revision after rendering",previous != nil && capture.previousWindowID==7)
        capture.clearPreviousWindowID()
        check("stop window reset preserves predecessor lifetime",previous != nil && capture.previousWindowID==nil)
        _=try await capture.capture(nil,preferDiff:true)
        check("cleared window identity prevents reuse of retained predecessor",predecessorFlags==[false,false])
        capture.clearPreviousRevision()
        check("start revision reset releases predecessor separately from window",previous==nil && capture.previousWindowID==7)
        capture.clearPreviousWindowID()
        recorder=Lifecycle(backend:backend);app=nil
        let observationChanges=Counter()
        withObservationTracking({_ = recorder!.isRecording},onChange:{observationChanges.increment()})
        try recorder.start()
        check("recording state observation notifies interface readers on start",observationChanges.value==1 && recorder.isRecording)
        withObservationTracking({_ = recorder!.isRecording},onChange:{observationChanges.increment()})
        recorder.stop(emitSessionEnded:false)
        check("recording state observation notifies interface readers on stop",observationChanges.value==2 && !recorder.isRecording)
        let sequenceChanges=Counter()
        withObservationTracking({_ = recorder!.sequence},onChange:{sequenceChanges.increment()})
        _=recorder.nextIdentity()
        check("shared sequence mutation keeps observation behavior",sequenceChanges.value==1)
        recorder=nil
        let resetClock=Sleeper();var resetRecords:[EventStreamRecord]=[]
        let resetQueue=EventStreamAXNotificationQueue(isRecording:{true},sleep:resetClock.sleep,emit:{resetRecords.append($0)})
        resetQueue.enqueue(late,key:"reset",notification:"AXSelectedRowsChanged");await drain()
        resetQueue.clearScheduledTaskOwners()
        check("start task-owner reset is separate from cancellation and records",resetQueue.scheduledCount==0 && resetQueue.pendingCount==1)
        resetClock.finish(0);await drain()
        check("dropping task owner alone does not cancel running Swift task",resetRecords==[late] && resetQueue.pendingCount==0)
        resetQueue.enqueue(late,key:"clear",notification:"AXSelectedRowsChanged");await drain();resetQueue.clearPendingRecords()
        check("start record reset does not cancel task owners",resetQueue.pendingCount==0 && resetQueue.scheduledCount==1)
        resetClock.finish(1);await drain();resetQueue.clearScheduledTaskOwners()
        check("cleared record cannot emit from its former delay",resetRecords==[late] && resetQueue.scheduledCount==0 && resetClock.pending.isEmpty)
        print("\(checks) checks")
    }
}
