import Foundation

// Timeline lifecycle: start, pause, resume and stop.
// The concrete native capture, memory and IPC composition is tracked separately.
// Required hooks bind the shared producer, record processor and memory pipeline.
@MainActor final class TimelineLifecycle<Producer:EventStreamCaptureProducing> {
    enum StopReason:UInt8 {case requested,serviceTerminated}
    enum Event {case started,paused,resumed,stopped(StopReason,durationSeconds:Double?)}
    struct Hooks {
        var shouldCapture:(Producer.Application)->Bool
        var onRecord:(EventStreamRecord)->Void
        var onSuppressedRecord:(EventStreamRecord)->Void
        var prepareStorage:()throws->Void
        var prepareMemory:()throws->Void
        var resetRecentApplications:()->Void
        var cancelPendingRecords:()->Void
        var processCompletedSegment:(EventStreamMetadata)->Void
        var recordEvent:(Event)->Void
        var scheduleResume:(Date,@escaping @MainActor ()->Void)->Task<Void,Never>
        var onError:(Error)->Void
    }
    static var stateDidChangeNotification:Notification.Name{.init("timelineServiceStateDidChange")}
    static var pauseResumeDateKey:String{"timeline.pauseResumeDate"}
    private let coordinator:EventStreamCaptureCoordinator<Producer>
    private let store:TimelineSegmentStore?
    private let rootURL:URL?
    private let defaults:UserDefaults
    private let hooks:Hooks
    private let now:()->Date
    private let calendar:()->Calendar
    private weak var notificationObject:AnyObject?
    private var writer:TimelineSegmentWriter?
    private var subscription:EventStreamCaptureSubscription?
    private var scheduledResumeTask:Task<Void,Never>?
    private var startedAt:Date?,endedAt:Date?

    init(coordinator:EventStreamCaptureCoordinator<Producer>,store:TimelineSegmentStore?,rootURL:URL?,
         defaults:UserDefaults,hooks:Hooks,notificationObject:AnyObject?=nil,
         now:@escaping ()->Date=Date.init,calendar:@escaping ()->Calendar={.current}) {
        self.coordinator=coordinator;self.store=store;self.rootURL=rootURL
        self.defaults=defaults;self.hooks=hooks;self.notificationObject=notificationObject
        self.now=now;self.calendar=calendar
    }
    var state:TimelineState {writer == nil ? .stopped : (subscription == nil ? .paused:.running)}
    var hasScheduledResume:Bool{scheduledResumeTask != nil}
    var segmentWriter:TimelineSegmentWriter?{writer}
    var pauseResumeDate:Date? {
        get{defaults.object(forKey:Self.pauseResumeDateKey)as?Date}
        set {
            if let newValue{defaults.set(newValue,forKey:Self.pauseResumeDateKey)}
            else{defaults.removeObject(forKey:Self.pauseResumeDateKey)}
        }
    }
    func status()->TimelineStatus {
        .init(state:state,eventStreamRootPath:rootURL?.path,
              currentSegmentEventsPath:writer?.currentSegment.eventsURL.path,
              currentSegmentMetadataPath:writer?.currentSegment.metadataURL.path,
              suppressedEventsPath:writer?.suppressedEventsURL?.path,startedAt:startedAt,endedAt:endedAt)
    }
    private func subscribe()throws->EventStreamCaptureSubscription {
        try coordinator.subscribe(shouldCapture:hooks.shouldCapture,onRecord:hooks.onRecord,onSuppressedRecord:hooks.onSuppressedRecord)
    }
    private func unsubscribe() {
        if let subscription{coordinator.unsubscribe(subscription);self.subscription=nil}
    }
    private func cancelResume() {scheduledResumeTask?.cancel();scheduledResumeTask=nil}
    private func scheduleResume(at date:Date) {
        pauseResumeDate=date
        scheduledResumeTask=hooks.scheduleResume(date){[weak self] in
            guard !Task.isCancelled,let self,self.state == .paused else{return}
            do{_ = try self.resume()}catch{self.hooks.onError(error)}
        }
    }
    private func announce(_ event:Event) {
        hooks.recordEvent(event)
        NotificationCenter.default.post(name:Self.stateDidChangeNotification,object:notificationObject ?? self)
    }
    @discardableResult func start()throws->TimelineStatus {
        if state == .running{return status()}
        if state == .paused {
            if let date=pauseResumeDate,date>now(){return status()}
            return try resume()
        }
        guard let store else{throw EventStreamRecordingStorageError.unavailable}
        let date=now()
        let completed:EventStreamMetadata?
        do{completed=try store.latestCompletedSegment(now:date)}catch{hooks.onError(error);completed=nil}
        startedAt=date;endedAt=nil
        hooks.resetRecentApplications();hooks.cancelPendingRecords()
        do {
            try hooks.prepareStorage()
            try hooks.prepareMemory()
            writer=try TimelineSegmentWriter(store:store,now:date)
            if let deadline=pauseResumeDate,deadline>now(){scheduleResume(at:deadline)}
            else {
                pauseResumeDate=nil
                subscription=try subscribe()
            }
        }catch {
            // Preparation, writer construction and
            // subscription failures share this cleanup, preserving the error.
            startedAt=nil;endedAt=nil;hooks.resetRecentApplications()
            unsubscribe();hooks.cancelPendingRecords();hooks.onError(error)
            writer?.close();writer=nil
            throw error
        }
        if let completed{hooks.processCompletedSegment(completed)}
        announce(.started)
        return status()
    }
    @discardableResult func resume()throws->TimelineStatus {
        guard state != .stopped else{throw TimelineError.recorderStopped}
        cancelResume();pauseResumeDate=nil
        if subscription != nil{return status()}
        do{subscription=try subscribe()}catch{subscription=nil;hooks.onError(error);throw error}
        announce(.resumed)
        return status()
    }
    @discardableResult func pause()throws->TimelineStatus {
        guard state != .stopped else{throw TimelineError.recorderStopped}
        cancelResume();pauseResumeDate=nil
        guard subscription != nil else{return status()}
        unsubscribe();announce(.paused)
        return status()
    }
    @discardableResult func pause(for duration:TimelinePauseDuration)throws->TimelineStatus {
        let date=duration.resumeDate(now:now(),calendar:calendar())
        let result=try pause()
        scheduleResume(at:date)
        return result
    }
    @discardableResult func stop(reason:StopReason)->TimelineStatus {
        cancelResume()
        if reason == .requested{pauseResumeDate=nil}
        guard state != .stopped else{return status()}
        let date=now();endedAt=date
        unsubscribe();hooks.cancelPendingRecords()
        // Stop discards the completed metadata; it does not enqueue
        // memory processing here.
        _=writer?.finish(now:now());writer?.close();writer=nil
        announce(.stopped(reason,durationSeconds:startedAt.map{max(0,date.timeIntervalSince($0))}))
        return status()
    }
}
