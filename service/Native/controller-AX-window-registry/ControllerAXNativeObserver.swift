import ApplicationServices
import Foundation

/// Native notification wrapper; reuses the existing source-bound C69 run-loop
/// worker with the caller's QoS instead of the Utility-only tree observer.
final class ControllerAXNativeObserver: @unchecked Sendable {
    struct Failure: Error { let status: Int32 }
    private final class Callback: @unchecked Sendable {
        weak var owner: ControllerAXNativeObserver?
        let handler: @Sendable (SettingsNativeAXElement, String, CFDictionary?) -> Void
        init(_ handler: @escaping @Sendable (SettingsNativeAXElement, String, CFDictionary?) -> Void) { self.handler = handler }
    }
    private final class Context {
        let observer: AXObserver
        let callback: Callback
        init(_ observer: AXObserver, _ callback: Callback) { self.observer = observer; self.callback = callback }
    }
    let observer: AXObserver
    private let callback: Callback
    private let pid: Int32
    private let lock = NSLock()
    private var worker: SettingsAXObserverRunLoop?

    init(pid: Int32, handler: @escaping @Sendable (SettingsNativeAXElement, String, CFDictionary?) -> Void) throws {
        typealias RawCallback = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
        let nativeCallback: RawCallback = { _, element, name, info, context in
            guard let context else { return }
            let callback = Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
            let dictionary = info.map { Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue() }
            guard dictionary == nil || dictionary as? [String: AnyObject] != nil, let owner = callback.owner else { return }
            withExtendedLifetime(owner) { callback.handler(.init(element: element), name as String, dictionary) }
        }
        var result: AXObserver?
        let status = AXObserverCreateWithInfoCallback(pid, unsafeBitCast(nativeCallback, to: AXObserverCallbackWithInfo.self), &result)
        guard status == .success, let result else { throw Failure(status: status.rawValue) }
        self.pid = pid; observer = result; callback = Callback(handler); callback.owner = self
    }
    func add(_ element: SettingsNativeAXElement, _ name: String) -> Int32 {
        AXObserverAddNotification(observer, element.element, name as CFString, Unmanaged.passUnretained(callback).toOpaque()).rawValue
    }
    func remove(_ element: SettingsNativeAXElement, _ name: String) -> Int32 {
        AXObserverRemoveNotification(observer, element.element, name as CFString).rawValue
    }
    func start(_ qos: QualityOfService) {
        lock.withLock {
            guard worker == nil else { return }
            let next = SettingsAXObserverRunLoop(source: AXObserverGetRunLoopSource(observer), context: Context(observer, callback),
                name: "AXNotificationObserver for pid \(pid)", qos: qos)
            worker = next; next.start()
        }
    }
    func stop() {
        let previous = lock.withLock { let old = worker; worker = nil; return old }
        previous?.detach()
    }
    deinit { stop() }
}

extension ControllerAXNotificationRegistration.Environment where Handle == ControllerAXNativeObserver, Node == SettingsNativeAXElement {
    static var native: Self {
        .init(create: { try ControllerAXNativeObserver(pid: $0, handler: $1) }, add: { $0.add($1, $2) },
            remove: { $0.remove($1, $2) }, start: { $0.start($1) }, stop: { $0.stop() })
    }
}

extension ControllerAXWindowRegistry where Node == SettingsNativeAXElement {
    /// The constructor assigns its windowObserver after registration
    /// starts. The weak controller callback cannot retain this registry in a cycle.
    func observeNative(pid: Int32, application: SettingsNativeAXElement) throws {
        let registration = try ControllerAXNotificationRegistration<ControllerAXNativeObserver, SettingsNativeAXElement>(
            pid: pid, application: application, environment: .native) { [weak self] element, name in
                guard let notification = Notification(rawValue: name) else { return }
                self?.receive(notification, element: element)
            }
        setObservation(.init(registerDestroyed: { try registration.register("AXUIElementDestroyed", for: $0) },
            removeDestroyed: { try registration.remove("AXUIElementDestroyed", for: $0) }))
    }
}
