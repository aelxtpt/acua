import Foundation
import ApplicationServices

private final class Owner {var deliveries=0}
private final class Trace {var calls:[String]=[]}
private final class Observation:EventStreamAXObservation {
    let trace:Trace,element:AXUIElement,failures:[String:AXError]
    let callback:(EventStreamAXNotificationEvent)->Void
    init(trace:Trace,element:AXUIElement,failures:[String:AXError],callback:@escaping (EventStreamAXNotificationEvent)->Void) {
        self.trace=trace;self.element=element;self.failures=failures;self.callback=callback
    }
    func register(_ name:String,for element:AXUIElement)throws {
        precondition(CFEqual(element,self.element));trace.calls.append(name)
        if let status=failures[name] {throw EventStreamNativeAXObserver.Failure(status:status)}
    }
    func start() {trace.calls.append("start")}
    func stop() {trace.calls.append("stop")}
    deinit {trace.calls.append("deinit")}
}

@main enum Tests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ label:String,_ value:Bool) {precondition(value,"FAIL: \(label)");checks += 1;print("PASS: \(label)")}
        func drain() async {for _ in 0..<30 {await Task.yield()}}
        let element=AXUIElementCreateApplication(-63000),trace=Trace()
        var failures:[String:AXError]=[:],constructionFails=false
        weak var created:Observation?
        let factory=EventStreamRecorderObservation(backend:.init(application:{pid in precondition(pid==40);trace.calls.append("application");return element},observer:{pid,callback in
            precondition(pid==40);trace.calls.append("observer")
            if constructionFails {throw EventStreamNativeAXObserver.Failure(status:.cannotComplete)}
            let result=Observation(trace:trace,element:element,failures:failures,callback:callback);created=result;return result
        }))
        var owner:Owner?=Owner(),events:[String]=[],timestamps:[Date]=[],callbackPIDs:[Int32]=[],bundles:[String?]=[],clockReads=0,envelopesValid=true
        var observer=try factory.make(processIdentifier:0,bundleIdentifier:"com.apple.Terminal",owner:owner!) {_,_,_,_,_ in fatalError()}
        check("nonpositive observer PID returns nil without construction",observer==nil && trace.calls.isEmpty)
        observer=try factory.make(processIdentifier:40,bundleIdentifier:"com.apple.Terminal",owner:owner!,now:{clockReads += 1;return Date(timeIntervalSince1970:7)}) {owner,event,pid,bundle,timestamp in
            MainActor.preconditionIsolated()
            envelopesValid = envelopesValid && CFEqual(event.element,element) && event.userInfo["tag"] as? String == "captured"
            owner.deliveries += 1;events.append(event.notification);timestamps.append(timestamp);callbackPIDs.append(pid);bundles.append(bundle)
        }
        check("native setup constructs application before observer and registrations",Array(trace.calls.prefix(2))==["application","observer"])
        check("terminal observer installs exact eight notifications before starting",Array(trace.calls.dropFirst(2))==EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:"com.apple.Terminal")+["start"])
        var rawObserver:AXObserver?
        // AXObserver creation against this process needs no windows or input.
        let status=AXObserverCreate(getpid(),{_,_,_,_ in},&rawObserver)
        guard status == .success,let rawObserver else {fatalError("cannot allocate local callback envelope")}
        let event=EventStreamAXNotificationEvent(observer:rawObserver,element:element,notification:"AXValueChanged",userInfo:["tag":"captured" as NSString])
        created!.callback(event)
        check("timestamp sampled before actor delivery",clockReads==1 && owner!.deliveries==0)
        await drain()
        check("callback reaches owner on actor with its envelope",events==["AXValueChanged"] && owner!.deliveries==1)
        check("callback preserves captured PID bundle and entry timestamp",callbackPIDs==[40] && bundles==["com.apple.Terminal"] && timestamps==[Date(timeIntervalSince1970:7)])
        check("callback preserves source element and user info payload",envelopesValid)
        let backgroundCallback=created!.callback
        await Task.detached {backgroundCallback(event)}.value
        await drain()
        check("worker callback is delivered on MainActor",owner!.deliveries==2 && events.count==2 && clockReads==2 && envelopesValid)
        created!.callback(event);owner=nil
        await drain()
        check("queued callback does not keep recorder alive",events.count==2 && clockReads==3)
        observer=nil
        check("observer release frees setup and callback owner",created==nil && trace.calls.last=="deinit")
        owner=Owner();trace.calls=[]
        failures=["AXSelectedRowsChanged":.cannotComplete,"AXSelectedCellsChanged":.notificationUnsupported]
        observer=try factory.make(processIdentifier:40,bundleIdentifier:nil,owner:owner!) {_,_,_,_,_ in}
        check("caller ignored registration errors allow subsequent registrations and start",Array(trace.calls.dropFirst(2))==EventStreamRecorderAXObservationPolicy.baseNotifications+["start"])
        observer=nil;trace.calls=[]
        failures=["AXSelectedColumnsChanged":.failure]
        do {observer=try factory.make(processIdentifier:40,bundleIdentifier:nil,owner:owner!) {_,_,_,_,_ in};fatalError("fatal registration accepted")}
        catch let error as EventStreamNativeAXObserver.Failure {check("unexpected registration error is preserved",error.status == .failure)}
        check("fatal registration stops setup without starting partial observer",trace.calls==["application","observer","AXFocusedWindowChanged","AXSelectedRowsChanged","AXSelectedColumnsChanged","deinit"] && created==nil)
        trace.calls=[];constructionFails=true
        do {observer=try factory.make(processIdentifier:40,bundleIdentifier:nil,owner:owner!) {_,_,_,_,_ in};fatalError("construction error accepted")}
        catch let error as EventStreamNativeAXObserver.Failure {check("observer construction errors are not treated as ignored registration",error.status == .cannotComplete)}
        check("failed observer construction performs no registration or start",trace.calls==["application","observer"])
        print("\(checks) checks")
    }
}
