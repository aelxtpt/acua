import Foundation
import ApplicationServices

/// AX notification observer registration/removal lifetime over an
/// injectable native handle. Generic handles permit tests without AX observers.
final class SettingsScrollRegistration<Handle: Sendable,Element: Hashable & Sendable>: @unchecked Sendable {
    struct Failure: Error { let status: Int32 }
    struct Environment: Sendable {
        let create: @Sendable (Int32,@escaping @Sendable (Element,CFDictionary?) -> Void) throws -> Handle
        let add: @Sendable (Handle,Element,String) -> Int32
        let remove: @Sendable (Handle,Element,String) -> Int32
        let start: @Sendable (Handle,QualityOfService) -> Void
        let stop: @Sendable (Handle) -> Void
        let role: @Sendable (Element) -> String?
    }
    private final class CallbackState: @unchecked Sendable {
        weak var owner: SettingsScrollRegistration?
        let handler: @Sendable (String) -> Void
        let role: @Sendable (Element) -> String?
        init(handler: @escaping @Sendable (String) -> Void,role: @escaping @Sendable (Element) -> String?) {
            self.handler=handler;self.role=role
        }
        func receive(_ element: Element,_ info: CFDictionary?) {
            guard let owner,Self.validInfo(info) else { return }
            withExtendedLifetime(owner) { handler(role(element) ?? "") }
        }
        static func validInfo(_ info: CFDictionary?) -> Bool { info == nil || info as? [String:AnyObject] != nil }
    }
    let handle: Handle
    private let environment: Environment
    private let element: Element
    private var registered=Set<String>()
    init(pid: Int32,element: Element,request: SystemSettingsScrollObservationRequest,environment: Environment,
         handler: @escaping @Sendable (String) -> Void) throws {
        self.environment=environment;self.element=element
        let callback=CallbackState(handler:handler,role:environment.role)
        handle=try environment.create(pid) { callback.receive($0,$1) }
        callback.owner=self
        for name in request.notifications {
            let status=environment.add(handle,element,name)
            if request.ignoredErrors.contains(status) { continue }
            guard status==AXError.success.rawValue || status==AXError.notificationAlreadyRegistered.rawValue else { throw Failure(status:status) }
            registered.insert(name)
        }
        environment.start(handle,request.qualityOfService)
    }
    func removeNotifications(_ names: [String]) throws {
        for name in names where registered.contains(name) {
            let status=environment.remove(handle,element,name)
            guard status==AXError.success.rawValue || status==AXError.notificationNotRegistered.rawValue else { throw Failure(status:status) }
            registered.remove(name)
        }
    }
    func stopMonitoring() { environment.stop(handle) }
    @MainActor func trackerObservation(request: SystemSettingsScrollObservationRequest) -> SystemSettingsScrollObservation {
        .init(lifetime:.init { [self] in _ = self },
            removeNotifications:{ [self] in try? removeNotifications(request.notifications) },
            stopMonitoring:{ [self] in stopMonitoring() })
    }
    deinit { environment.stop(handle) }
}
