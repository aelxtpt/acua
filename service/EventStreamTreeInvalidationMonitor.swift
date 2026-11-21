import Foundation
import ApplicationServices

protocol EventStreamAXObservation:AnyObject {
    func register(_ notification:String,for element:AXUIElement)throws
    func start()
    func stop()
}

// An observer has its own Utility run loop.
// The worker retains callback context until even an in-flight callback returns.
final class EventStreamAXObserverRunLoop:Thread,@unchecked Sendable {
    private let publication=NSLock()
    private var loop:CFRunLoop?
    private let source:CFRunLoopSource
    private let context:AnyObject
    private let configurationBarrier:()->Void
    init(source:CFRunLoopSource,context:AnyObject,name:String,
         configurationBarrier:@escaping ()->Void = {DispatchQueue.main.sync {}}) {
        self.source=source;self.context=context;self.configurationBarrier=configurationBarrier
        super.init();self.name=name;qualityOfService = .utility
    }
    override func main() {
        autoreleasepool {
            let current=CFRunLoopGetCurrent()!
            publication.lock();loop=current;publication.unlock()
            defer {
                CFRunLoopRemoveSource(current,source,.defaultMode)
                publication.lock();loop=nil;publication.unlock()
                withExtendedLifetime(context) {}
            }
            guard !isCancelled else {return}
            // Synchronize with the main queue before attaching.
            configurationBarrier()
            guard !isCancelled else {return}
            CFRunLoopAddSource(current,source,.defaultMode)
            var configuration=CFRunLoopSourceContext()
            configuration.perform={_ in}
            let keepAlive=CFRunLoopSourceCreate(nil,0,&configuration)!
            CFRunLoopAddSource(current,keepAlive,.defaultMode)
            defer {CFRunLoopSourceInvalidate(keepAlive)}
            while !isCancelled {CFRunLoopRun()}
        }
    }
    override func cancel() {
        super.cancel()
        publication.lock();let current=loop;publication.unlock()
        if let current {
            // Use the executing loop, avoiding a queued block
            // retaining its own loop if cancellation wins before it can run.
            CFRunLoopPerformBlock(current,CFRunLoopMode.commonModes.rawValue) {CFRunLoopStop(CFRunLoopGetCurrent())}
            CFRunLoopWakeUp(current)
        }
    }
    func detach() {
        publication.lock();let current=loop;publication.unlock()
        if let current {CFRunLoopRemoveSource(current,source,.defaultMode)}
        cancel()
    }
}

struct EventStreamAXNotificationEvent {
    let observer:AXObserver
    let element:AXUIElement
    let notification:String
    let userInfo:[String:AnyObject]
}

final class EventStreamNativeAXObserver:EventStreamAXObservation {
    struct Failure:Error {let status:AXError}
    private final class Callback {
        let handler:(EventStreamAXNotificationEvent)->Void
        weak var owner:EventStreamNativeAXObserver?
        // Retain a per-notification set even for an already
        // registered target. The worker also owns this callback context.
        var registrations:[String:Set<EventStreamSnapshotAXIdentity>]=[:]
        init(_ handler:@escaping (EventStreamAXNotificationEvent)->Void) {self.handler=handler}
    }
    // Retained by the worker independently of the wrapper during teardown.
    private final class Context {
        let observer:AXObserver,callback:Callback
        init(_ observer:AXObserver,_ callback:Callback) {self.observer=observer;self.callback=callback}
    }
    private let observer:AXObserver
    private let callback:Callback
    private let pid:pid_t
    private var worker:EventStreamAXObserverRunLoop?
    convenience init(pid:pid_t,handler:@escaping (AXUIElement,String)->Void)throws {
        try self.init(pid:pid,onNotification:{handler($0.element,$0.notification)})
    }
    init(pid:pid_t,onNotification:@escaping (EventStreamAXNotificationEvent)->Void)throws {
        let callback=Callback(onNotification);var result:AXObserver?
        // AppKit can pass NULL info even though the SDK imports CFDictionary
        // as nonoptional. Decode a nullable C pointer before making Swift refs.
        typealias RawCallback = @convention(c) (AXObserver,AXUIElement,CFString,UnsafeRawPointer?,UnsafeMutableRawPointer?)->Void
        let nativeCallback:RawCallback = {observer,element,name,infoPointer,context in
            guard let context else {return}
            let callback=Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
            // Conditionally bridge String-keyed userInfo, then
            // weak-loads the observer owner. A worker can outlive that owner.
            let userInfo=infoPointer.map {Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue()}
            guard let info=EventStreamNativeAXObserver.decodeUserInfo(userInfo),
                  let owner=callback.owner else {return}
            withExtendedLifetime(owner) {
                callback.handler(.init(observer:observer,element:element,notification:name as String,userInfo:info))
            }
        }
        let status=AXObserverCreateWithInfoCallback(pid,unsafeBitCast(nativeCallback,to:AXObserverCallbackWithInfo.self),&result)
        guard status == .success,let result else {throw Failure(status:status)}
        self.pid=pid;observer=result;self.callback=callback
        callback.owner=self
    }
    static func decodeUserInfo(_ userInfo:CFDictionary?)->[String:AnyObject]? {
        // Bridge like Dictionary._conditionallyBridgeFromObjectiveC.
        // On this Foundation a null NSDictionary bridges to an empty value;
        // an ordinary optional cast would incorrectly discard that callback.
        guard let userInfo else {return [:]}
        return userInfo as? [String:AnyObject]
    }
    static func acceptsRegistration(_ status:AXError)->Bool {
        // Monitor callers pass no additional ignored errors.
        status == .success || status == .notificationAlreadyRegistered
    }
    func register(_ notification:String,for element:AXUIElement)throws {
        try register(notification, for: element, ignoring: nil)
    }
    func register(_ notification:String,for element:AXUIElement,ignoring ignoredStatus:AXError?)throws {
        let status=AXObserverAddNotification(observer,element,notification as CFString,Unmanaged.passUnretained(callback).toOpaque())
        if status == ignoredStatus {return}
        guard Self.acceptsRegistration(status) else {throw Failure(status:status)}
        callback.registrations[notification,default:[]].insert(.init(element:element))
    }
    func start() {
        guard worker==nil else {return}
        let next=EventStreamAXObserverRunLoop(source:AXObserverGetRunLoopSource(observer),
            context:Context(observer,callback),name:"AXNotificationObserver for pid \(pid)")
        worker=next;next.start()
    }
    func stop() {let previous=worker;worker=nil;previous?.detach()}
    deinit {stop()}
}

struct EventStreamInvalidationMonitorIO {
    var processIdentifier:(AXUIElement)throws->pid_t
    var observer:(pid_t,@escaping (AXUIElement,String)->Void)throws->any EventStreamAXObservation
    static var native:Self {
        .init(processIdentifier:{element in
            var pid:pid_t = -1
            let status=AXUIElementGetPid(element,&pid)
            guard status == .success else {throw EventStreamNativeAXObserver.Failure(status:status)}
            return pid
        },observer:{try EventStreamNativeAXObserver(pid:$0,handler:$1)})
    }
}

final class EventStreamTreeInvalidationMonitor:@unchecked Sendable {
    struct State:Equatable {
        var layoutChanged=false
        var destroyedElements:Set<EventStreamSnapshotAXIdentity>=[]
    }
    private final class Storage:@unchecked Sendable {
        let lock=NSLock()
        var value=State()
        func receive(_ element:AXUIElement,_ notification:String) {
            lock.lock();defer {lock.unlock()}
            switch notification {
            case kAXLayoutChangedNotification:value.layoutChanged=true
            case kAXUIElementDestroyedNotification:value.destroyedElements.insert(.init(element:element))
            default:break
            }
        }
    }
    private let storage=Storage()
    private let observation:(any EventStreamAXObservation)?
    var hasObserver:Bool {observation != nil}
    init(application:AXUIElement,io:EventStreamInvalidationMonitorIO = .native) {
        let state=storage
        var pending:(any EventStreamAXObservation)?
        do {
            let pid=try io.processIdentifier(application)
            let observer=try io.observer(pid) {element,name in state.receive(element,name)}
            pending=observer
            try observer.register(kAXLayoutChangedNotification,for:application)
            try observer.register(kAXUIElementDestroyedNotification,for:application)
            observer.start();observation=observer
        } catch {
            pending?.stop();observation=nil
        }
    }
    var state:State {withState {$0}}
    func requiresRefetch(_ element: AXUIElement) -> Bool {
        guard hasObserver else { return true }
        let identity = EventStreamSnapshotAXIdentity(element: element)
        return withState { $0.layoutChanged || $0.destroyedElements.contains(identity) }
    }
    // Consumer owns reset/consumption policy; reading never resets events.
    func withState<Result>(_ body:(inout State)throws->Result) rethrows->Result {
        storage.lock.lock();defer {storage.lock.unlock()}
        return try body(&storage.value)
    }
    deinit {observation?.stop()}
}
