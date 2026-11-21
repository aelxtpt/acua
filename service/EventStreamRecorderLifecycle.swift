import Foundation
import Observation

// Recorder lifecycle ports. Ports bind to actual
// input, observer, buffer and capture owners; they do not substitute records.
@Observable @MainActor final class EventStreamRecorderLifecycle<Application>:@preconcurrency EventStreamCaptureProducing {
    struct Backend {
        var now:()->Date = Date.init
        var clearPreviousRevision:()->Void
        var clearPreviousWindowID:()->Void
        var clearURLs:()->Void
        var clearMouseDown:()->Void
        var clearTextBuffer:()->Void
        var clearTerminalBuffer:()->Void
        var clearSelectionRecords:()->Void
        var clearSelectionTaskOwners:()->Void
        // EventTap.startMonitoring silently tolerates an unavailable tap.
        var installInputTap:()->Void
        var subscribeFrontmost:()->Void
        var currentApplication:()->Application?
        var refreshApplication:(Application,Date)->Void
        var flushText:()->Void
        var flushTerminal:()->Void
        var flushSelectionAfterRecordingGuard:()->Void
        var stopInputTap:()->Void
        var unsubscribeFrontmost:()->Void
        var stopAXObserver:()->Void
        var cancelDelayedTasks:()->Void
        var clearCurrentApplication:()->Void
        var capturePolicyChanged:(((Application)->Bool)?)->Void
    }
    private let backend:Backend
    private(set) var isRecording=false
    private(set) var sequence=0
    var onRecordStored:((EventStreamRecord)->Void)?
    var onSuppressedRecordStored:((EventStreamRecord)->Void)?
    var shouldCaptureApplication:((Application)->Bool)? {
        didSet {backend.capturePolicyChanged(shouldCaptureApplication)}
    }
    init(backend:Backend) {self.backend=backend}
    func nextIdentity(at timestamp:Date)->EventStreamRecordIdentity {
        sequence += 1 // Checked overflow.
        return .init(id:sequence,timestamp:timestamp)
    }
    func nextIdentity()->EventStreamRecordIdentity {nextIdentity(at:backend.now())}
    func makeSessionBoundaryRecord(kind:EventStreamEventKind)->EventStreamRecord {
        let identity=nextIdentity()
        return .init(id:identity.id,timestamp:identity.timestamp,kind:kind)
    }
    func start() throws {
        guard !isRecording else {return}
        backend.clearPreviousRevision();backend.clearPreviousWindowID()
        backend.clearURLs();backend.clearMouseDown();backend.clearTextBuffer();backend.clearTerminalBuffer()
        backend.clearSelectionRecords();backend.clearSelectionTaskOwners()
        isRecording=true
        backend.installInputTap();backend.subscribeFrontmost()
        emitInitialBoundaryAndRefresh()
    }
    private func emitInitialBoundaryAndRefresh() {
        guard isRecording else {return}
        let record=makeSessionBoundaryRecord(kind:.sessionStarted)
        onRecordStored?(record)
        // Boundary construction consumes an identity even without a callback.
        // Query after consumer delivery, with no added reentrancy flag/epoch.
        if let app=backend.currentApplication() {backend.refreshApplication(app,backend.now())}
    }
    func refreshCurrentApplication() {
        guard isRecording else {return}
        if let app=backend.currentApplication() {backend.refreshApplication(app,backend.now())}
    }
    func flushPendingRecords() {
        guard isRecording else {return}
        backend.flushText();backend.flushTerminal();backend.flushSelectionAfterRecordingGuard()
    }
    func stop(emitSessionEnded:Bool) {
        guard isRecording else {return}
        flushPendingRecords()
        if emitSessionEnded {
            let record=makeSessionBoundaryRecord(kind:.sessionEnded)
            onRecordStored?(record)
        }
        backend.stopInputTap();backend.unsubscribeFrontmost();backend.stopAXObserver()
        backend.cancelDelayedTasks();backend.clearCurrentApplication()
        // stop retains previous revision and any reentrant text/terminal buffer.
        backend.clearPreviousWindowID();backend.clearURLs();backend.clearMouseDown()
        isRecording=false
    }
    func store(_ delivery:EventStreamRecordDelivery) {
        // The common async completion dispatches directly; it adds no
        // second recording gate after capture and has no suppressed fallback.
        if delivery.isSuppressed {onSuppressedRecordStored?(delivery.record)}
        else {onRecordStored?(delivery.record)}
    }
}

// The frontmost callback samples Date before hopping, then loads
// the recorder weakly only on MainActor. Subscriptions do not seed a callback.
final class EventStreamRecorderFrontmostDelivery<Owner:AnyObject,Application>:@unchecked Sendable {
    private weak var owner:Owner?
    private let now:()->Date
    private let deliver:@MainActor (Owner,Application,Date)->Void
    init(owner:Owner,now:@escaping ()->Date=Date.init,deliver:@escaping @MainActor (Owner,Application,Date)->Void) {
        self.owner=owner;self.now=now;self.deliver=deliver
    }
    func receive(_ application:Application) {
        let timestamp=now()
        Task { @MainActor [self] in
            guard let owner else {return}
            deliver(owner,application,timestamp)
        }
    }
}
