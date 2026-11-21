import Foundation
import ApplicationServices

private final class ObservationDiary {
    var registrations:[String]=[],elements:[EventStreamSnapshotAXIdentity]=[]
    var starts=0,stops=0,releases=0
    var failRegistration:Int?
    var handler:((AXUIElement,String)->Void)?
}
private final class ControlledObservation:EventStreamAXObservation {
    let diary:ObservationDiary
    init(_ diary:ObservationDiary,_ handler:@escaping (AXUIElement,String)->Void) {self.diary=diary;diary.handler=handler}
    func register(_ notification:String,for element:AXUIElement)throws {
        diary.registrations.append(notification);diary.elements.append(.init(element:element))
        if diary.registrations.count==diary.failRegistration {throw MonitorTests.Expected.failure}
    }
    func start() {diary.starts += 1}
    func stop() {diary.stops += 1}
    deinit {diary.releases += 1}
}
private final class WorkerContext {}
private final class WeakWorkerContext {
    weak var value:WorkerContext?
    init(_ value:WorkerContext?) {self.value=value}
}
// Published once before concurrentPerform; fields are immutable and only the
// monitor's locked storage is accessed from its callback and state reads.
private final class ConcurrentCallbacks:@unchecked Sendable {
    let references:[AXUIElement],handler:(AXUIElement,String)->Void
    let monitor:EventStreamTreeInvalidationMonitor
    init(_ references:[AXUIElement],_ handler:@escaping (AXUIElement,String)->Void,_ monitor:EventStreamTreeInvalidationMonitor) {
        self.references=references;self.handler=handler;self.monitor=monitor
    }
    func receive(_ index:Int) {
        handler(references[index%references.count],index%5==0 ? kAXLayoutChangedNotification:kAXUIElementDestroyedNotification)
        _=monitor.state
    }
}

@main enum MonitorTests {
    enum Expected:Error {case failure}
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure()->Bool) {
        guard condition() else {fatalError("FAIL: \(label)")}
        checks += 1;print("PASS: \(label)")
    }
    static func wait(until condition:()->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+4
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime<deadline else {throw Expected.failure}
            try await Task.sleep(nanoseconds:2_000_000)
        }
    }
    static func source()->CFRunLoopSource {
        var context=CFRunLoopSourceContext();context.perform={_ in}
        return CFRunLoopSourceCreate(nil,0,&context)!
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let app=AXUIElementCreateApplication(30000),element=AXUIElementCreateApplication(30001)
        var factoryCalls=0
        let noPID=EventStreamTreeInvalidationMonitor(application:app,io:.init(processIdentifier:{_ in throw Expected.failure},observer:{_,_ in
            factoryCalls += 1;throw Expected.failure
        }))
        check("PID failure leaves usable empty monitor without creating an observer",!noPID.hasObserver && noPID.state == .init() && factoryCalls==0)
        let noObserver=EventStreamTreeInvalidationMonitor(application:app,io:.init(processIdentifier:{_ in 30000},observer:{pid,_ in
            check("observer factory receives actual resolved PID",pid==30000);throw Expected.failure
        }))
        check("observer creation failure retains empty monitor state",!noObserver.hasObserver && noObserver.state == .init())
        check("a missing observer requires a fresh tree", noObserver.requiresRefetch(element))
        for failure in 1...2 {
            let diary=ObservationDiary();diary.failRegistration=failure
            let failed=EventStreamTreeInvalidationMonitor(application:app,io:.init(processIdentifier:{_ in 30000},observer:{_,handler in ControlledObservation(diary,handler)}))
            check("registration failure \(failure) prevents worker start",!failed.hasObserver && diary.starts==0 && diary.registrations.count==failure)
            check("registration failure \(failure) cleans partially acquired observer",diary.stops==1 && diary.releases==1)
            check("registration failure \(failure) leaves locked state accessible",failed.state == .init())
        }
        check("success and already-registered are accepted",EventStreamNativeAXObserver.acceptsRegistration(.success) && EventStreamNativeAXObserver.acceptsRegistration(.notificationAlreadyRegistered))
        check("unsupported failed invalid and duplicate-unregistered errors are rejected",[AXError.notificationUnsupported,.cannotComplete,.invalidUIElement,.notificationNotRegistered].allSatisfy {!EventStreamNativeAXObserver.acceptsRegistration($0)})
        let diary=ObservationDiary()
        var monitor:EventStreamTreeInvalidationMonitor? = .init(application:app,io:.init(processIdentifier:{_ in 30000},observer:{_,handler in ControlledObservation(diary,handler)}))
        check("monitor starts only after ordered application registrations",monitor!.hasObserver && diary.starts==1 && diary.registrations==[kAXLayoutChangedNotification,kAXUIElementDestroyedNotification] && diary.elements.allSatisfy {$0 == .init(element:app)})
        diary.handler!(element,kAXTitleChangedNotification)
        check("unrelated notification leaves both state fields unchanged",monitor!.state == .init())
        check("a healthy monitor permits reuse after an unrelated notification", !monitor!.requiresRefetch(element))
        do {
            let root = AXReference(element: app)
            var settled = AXSettledWindow(processKey: "old-process", root: root, monitor: monitor!)
            let sameWindow = AXUIElementCreateApplication(30000)
            check("settling cache accepts an equivalent window identity", settled.isCurrent(processKey: "old-process", window: sameWindow))
            check("settling cache rejects changed processes and windows or a menu without a window",
                  !settled.isCurrent(processKey: "new-process", window: app) &&
                  !settled.isCurrent(processKey: "old-process", window: element) &&
                  !settled.isCurrent(processKey: "old-process", window: nil))
            settled.recordChildren(Array(repeating: element, count: 100), returnedCount: 100, for: root)
            check("a child list at the settling limit requires a live read", settled.children[root] == nil)
            settled.recordChildren([element], returnedCount: 2, for: root)
            check("an AX child list containing an undecodable entry requires a live read", settled.children[root] == nil)
            settled.recordChildren([element], returnedCount: 1, for: root)
            check("a complete AX child list can be reused", settled.children[root]?.first.map { CFEqual($0, element) } == true)
            settled.recordChildren([], returnedCount: 0, for: root)
            check("a complete empty list is distinct from an unread child list", settled.children[root]?.isEmpty == true)
            diary.handler!(element, kAXUIElementDestroyedNotification)
            check("the action tree cache is discarded if a descendant was destroyed", !settled.isCurrent(processKey: "old-process", window: app))
            monitor!.withState { $0.destroyedElements.removeAll() }
            diary.handler!(app, kAXLayoutChangedNotification)
            check("the action tree cache is discarded after a layout event", !settled.isCurrent(processKey: "old-process", window: app))
            monitor!.withState { $0.layoutChanged = false }
            let unobserved = AXSettledWindow(processKey: "old-process", root: root, monitor: noObserver)
            check("a settling cache without a monitor cannot supply capture data", !unobserved.isCurrent(processKey: "old-process", window: app))
        }
        diary.handler!(element,kAXUIElementDestroyedNotification);diary.handler!(element,kAXUIElementDestroyedNotification)
        check("repeated destroyed events retain one native identity",monitor!.state.destroyedElements == [.init(element:element)] && !monitor!.state.layoutChanged)
        check("a destruction refetches only the affected identity", monitor!.requiresRefetch(element) && !monitor!.requiresRefetch(app))
        diary.handler!(app,kAXLayoutChangedNotification)
        check("layout event preserves accumulated destroyed identities",monitor!.state.layoutChanged && monitor!.state.destroyedElements.count==1)
        check("a layout change requires refetch for any identity", monitor!.requiresRefetch(app) && monitor!.requiresRefetch(element))
        let before=monitor!.state
        check("repeated state reads do not consume events",monitor!.state==before && monitor!.state==before)
        do {try monitor!.withState {_ in throw Expected.failure}} catch Expected.failure {}
        check("throwing state consumer releases lock",monitor!.state==before)
        monitor!.withState {$0.layoutChanged=false}
        check("consumer can reset layout independently of destruction set",!monitor!.state.layoutChanged && monitor!.state.destroyedElements.count==1)
        monitor!.withState {$0.destroyedElements.removeAll()}
        let references=(0..<32).map {AXUIElementCreateApplication(pid_t(31000+$0))}
        do {
            let callbacks=ConcurrentCallbacks(references,diary.handler!,monitor!)
            DispatchQueue.concurrentPerform(iterations:4096) {callbacks.receive($0)}
            check("concurrent callbacks and readers retain all distinct identities",monitor!.state.layoutChanged && monitor!.state.destroyedElements==Set(references.map {EventStreamSnapshotAXIdentity(element:$0)}))
        }
        monitor=nil
        check("monitor destruction stops and releases its observer",diary.stops==1 && diary.releases==1)
        // A native callback already in flight retains the independent storage.
        diary.handler!(element,kAXLayoutChangedNotification)
        check("in-flight callback storage survives wrapper destruction",diary.stops==1 && diary.releases==1)
        diary.handler=nil

        var early:EventStreamAXObserverRunLoop? = .init(source:source(),context:WorkerContext(),name:"CUA monitor cancelled before start",configurationBarrier:{fatalError("cancelled worker configured")})
        early!.cancel();early!.start()
        try await wait {early!.isFinished}
        check("cancellation before worker initialization finishes cleanly",early!.isCancelled && early!.isFinished)
        early=nil
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        var payload:WorkerContext?=WorkerContext();let retained=WeakWorkerContext(payload)
        var racing:EventStreamAXObserverRunLoop? = .init(source:source(),context:payload!,name:"CUA monitor stop during configuration",configurationBarrier:{entered.signal();release.wait()})
        payload=nil;racing!.start()
        try await wait {entered.wait(timeout:.now()) == .success}
        check("worker uses Utility quality and retains callback context",racing!.qualityOfService == .utility && retained.value != nil)
        racing!.detach();release.signal()
        try await wait {racing!.isFinished}
        check("stop during configuration cannot start a lingering run loop",racing!.isCancelled && racing!.isFinished)
        racing=nil
        check("finished worker releases callback context",retained.value==nil)
        let workers=(0..<32).map {i in EventStreamAXObserverRunLoop(source:source(),context:WorkerContext(),name:"CUA monitor race \(i)",configurationBarrier:{})}
        for worker in workers {worker.start()}
        for worker in workers {worker.detach();worker.detach()}
        try await wait {workers.allSatisfy(\.isFinished)}
        check("repeated stop across initialized and uninitialized workers terminates all",workers.allSatisfy {$0.isFinished && $0.isCancelled})
        print("EVENT STREAM INVALIDATION MONITOR: \(checks) checks passed")
    }
}
