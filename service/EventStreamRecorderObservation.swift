import Foundation
import ApplicationServices

// The callback timestamps/retains its payload before the MainActor hop and
// weak-loads the recorder only after that hop.
final class EventStreamRecorderAXDelivery<Owner:AnyObject>:@unchecked Sendable {
    private weak var owner:Owner?
    private let pid:Int32,bundleIdentifier:String?
    private let now:()->Date
    private let deliver:@MainActor (Owner,EventStreamAXNotificationEvent,Int32,String?,Date)->Void
    init(owner:Owner,pid:Int32,bundleIdentifier:String?,now:@escaping ()->Date=Date.init,
         deliver:@escaping @MainActor (Owner,EventStreamAXNotificationEvent,Int32,String?,Date)->Void) {
        self.owner=owner;self.pid=pid;self.bundleIdentifier=bundleIdentifier;self.now=now;self.deliver=deliver
    }
    func receive(_ event:EventStreamAXNotificationEvent) {
        let timestamp=now()
        Task { @MainActor [self] in
            guard let owner else {return}
            deliver(owner,event,pid,bundleIdentifier,timestamp)
        }
    }
}

// Recorder setup and shared observer constructor. Lifecycle
// replacement/error reporting remain the application controller's job.
@MainActor struct EventStreamRecorderObservation {
    struct Backend {
        var application:(Int32)->AXUIElement
        var observer:(Int32,@escaping (EventStreamAXNotificationEvent)->Void)throws->any EventStreamAXObservation
    }
    let backend:Backend
    init(backend:Backend) {self.backend=backend}
    init(snapshots:EventStreamNativeSnapshots) {
        backend = .init(application:{snapshots.node(AXUIElementCreateApplication($0)).element},
            observer:{try EventStreamNativeAXObserver(pid:$0,onNotification:$1)})
    }
    func make<Owner:AnyObject>(processIdentifier pid:Int32,bundleIdentifier:String?,owner:Owner,
        now:@escaping ()->Date=Date.init,
        deliver:@escaping @MainActor (Owner,EventStreamAXNotificationEvent,Int32,String?,Date)->Void)throws->(any EventStreamAXObservation)? {
        guard pid>0 else {return nil}
        let application=backend.application(pid)
        let notifications=EventStreamRecorderAXObservationPolicy.notifications(bundleIdentifier:bundleIdentifier)
        let delivery=EventStreamRecorderAXDelivery(owner:owner,pid:pid,bundleIdentifier:bundleIdentifier,now:now,deliver:deliver)
        let observer=try backend.observer(pid,delivery.receive)
        for notification in notifications {
            do {try observer.register(notification,for:application)}
            catch let failure as EventStreamNativeAXObserver.Failure
                where EventStreamRecorderAXObservationPolicy.ignoredRegistrationErrors.contains(failure.status.rawValue) {
                // Return immediately for caller-ignored errors;
                // unlike success/alreadyRegistered, it does NOT retain target.
                continue
            }
        }
        observer.start()
        return observer
    }
}
