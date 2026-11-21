import Foundation
import ApplicationServices

struct SettingsNativeAXElement: Hashable, @unchecked Sendable {
    let element: AXUIElement
    static func == (lhs: Self,rhs: Self) -> Bool { CFEqual(lhs.element,rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

final class SettingsNativeAXObserver: @unchecked Sendable {
    struct Failure: Error { let status: Int32 }
    private final class CallbackState: @unchecked Sendable {
        weak var owner: SettingsNativeAXObserver?
        let handler: @Sendable (SettingsNativeAXElement,String,CFDictionary?) -> Void
        init(_ handler: @escaping @Sendable (SettingsNativeAXElement,String,CFDictionary?) -> Void) { self.handler=handler }
    }
    private final class Context {
        let observer: AXObserver
        let state: CallbackState
        init(_ observer: AXObserver,_ state: CallbackState) { self.observer=observer;self.state=state }
    }
    let observer: AXObserver
    private let state: CallbackState
    private let pid: Int32
    private let lock=NSLock()
    private var worker: SettingsAXObserverRunLoop?
    convenience init(pid: Int32,handler: @escaping @Sendable (SettingsNativeAXElement,CFDictionary?) -> Void) throws {
        try self.init(pid:pid,namedHandler:{ element,_,info in handler(element,info) })
    }
    init(pid: Int32,namedHandler handler: @escaping @Sendable (SettingsNativeAXElement,String,CFDictionary?) -> Void) throws {
        typealias Callback = @convention(c) (AXObserver,AXUIElement,CFString,UnsafeRawPointer?,UnsafeMutableRawPointer?) -> Void
        let callback: Callback = { _,element,name,info,context in
            guard let context else { return }
            let state=Unmanaged<CallbackState>.fromOpaque(context).takeUnretainedValue()
            guard let owner=state.owner else { return }
            let dictionary=info.map { Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue() }
            withExtendedLifetime(owner) { state.handler(.init(element:element),name as String,dictionary) }
        }
        var result: AXObserver?
        let status=AXObserverCreateWithInfoCallback(pid,unsafeBitCast(callback,to:AXObserverCallbackWithInfo.self),&result)
        guard status == .success,let result else { throw Failure(status:status.rawValue) }
        self.pid=pid;observer=result;state=CallbackState(handler);state.owner=self
    }
    func add(_ element: SettingsNativeAXElement,_ name: String) -> Int32 {
        AXObserverAddNotification(observer,element.element,name as CFString,Unmanaged.passUnretained(state).toOpaque()).rawValue
    }
    func remove(_ element: SettingsNativeAXElement,_ name: String) -> Int32 {
        AXObserverRemoveNotification(observer,element.element,name as CFString).rawValue
    }
    func start(_ qos: QualityOfService) {
        lock.withLock {
            guard worker == nil else { return }
            let next=SettingsAXObserverRunLoop(source:AXObserverGetRunLoopSource(observer),context:Context(observer,state),
                name:"AXNotificationObserver for pid \(pid)",qos:qos)
            worker=next;next.start()
        }
    }
    func stop() {
        let previous=lock.withLock { let old=worker;worker=nil;return old }
        previous?.detach()
    }
    deinit { stop() }
}

/// Shares the RunLoopTask/AX observer contract: its configuration
/// waits for the main queue, attaches to default mode and retains callback state
/// until an in-flight callback and its worker have both finished.
final class SettingsAXObserverRunLoop: Thread, @unchecked Sendable {
    private let publication=NSLock()
    private var loop: CFRunLoop?
    private let source: CFRunLoopSource
    private let context: AnyObject
    init(source: CFRunLoopSource,context: AnyObject,name: String,qos: QualityOfService) {
        self.source=source;self.context=context
        super.init();self.name=name;qualityOfService=qos
    }
    override func main() {
        autoreleasepool {
            let current=CFRunLoopGetCurrent()!
            publication.withLock { loop=current }
            defer {
                CFRunLoopRemoveSource(current,source,.defaultMode)
                publication.withLock { loop=nil }
                withExtendedLifetime(context) {}
            }
            guard !isCancelled else { return }
            DispatchQueue.main.sync {}
            guard !isCancelled else { return }
            CFRunLoopAddSource(current,source,.defaultMode)
            var configuration=CFRunLoopSourceContext();configuration.perform={ _ in }
            let keepAlive=CFRunLoopSourceCreate(nil,0,&configuration)!
            CFRunLoopAddSource(current,keepAlive,.defaultMode)
            defer { CFRunLoopSourceInvalidate(keepAlive) }
            while !isCancelled { CFRunLoopRun() }
        }
    }
    func detach() {
        let current=publication.withLock { loop }
        if let current { CFRunLoopRemoveSource(current,source,.defaultMode) }
        cancel()
    }
    func runLoopSnapshot() -> CFRunLoop? { publication.withLock { loop } }
    override func cancel() {
        super.cancel()
        if let current=publication.withLock({ loop }) {
            CFRunLoopPerformBlock(current,CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(current)
        }
    }
}

extension SettingsScrollRegistration.Environment where Handle == SettingsNativeAXObserver,Element == SettingsNativeAXElement {
    static var native: Self {
        .init(create:{ try SettingsNativeAXObserver(pid:$0,handler:$1) },add:{ $0.add($1,$2) },remove:{ $0.remove($1,$2) },
            start:{ $0.start($1) },stop:{ $0.stop() },role:{ element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element.element,"AXRole" as CFString,&value) == .success else { return nil }
                return value as? String
            })
    }
}
