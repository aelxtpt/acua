import Foundation
import AppKit
import ApplicationServices

// Focused-window branch.
// The allocated identity uses the callback-entry date. Capture resolves its
// current context when the delayed callback runs, without a supplied target.
@MainActor final class EventStreamLayoutNotificationTask {
    private let isRecording:()->Bool
    private let sleep:(Duration) async throws->Void
    private let lifetimeOwner:()->AnyObject?
    private let capture:(EventStreamRecordIdentity) async->Void
    private var task:Task<Void,Never>?
    var hasScheduledTask:Bool {task != nil}
    init(isRecording:@escaping ()->Bool,
         sleep:@escaping (Duration) async throws->Void = {try await ContinuousClock().sleep(for:$0)},
         lifetimeOwner:@escaping ()->AnyObject? = {nil},
         capture:@escaping (EventStreamRecordIdentity) async->Void) {
        self.isRecording=isRecording;self.sleep=sleep;self.capture=capture
        self.lifetimeOwner=lifetimeOwner
    }
    func schedule(_ identity:EventStreamRecordIdentity) {
        task?.cancel()
        let owner=lifetimeOwner()
        task=Task { @MainActor [self,owner] in
            defer {withExtendedLifetime(owner) {}}
            try? await sleep(.milliseconds(250))
            guard !Task.isCancelled,isRecording() else {return}
            await capture(identity)
        }
    }
    // The completed layout task stays in its slot until replacement
    // or cleanup. A record flush does not force this delayed capture to run.
    func cancel() {task?.cancel();task=nil}
    deinit {task?.cancel()}
}

// Application policy uses the captured observer PID and is skipped
// if that PID no longer resolves. No current-observer-PID equality is added.
@MainActor final class EventStreamRecorderNotificationDispatcher<Reference,Application> {
    struct Backend {
        var isRecording:()->Bool
        var runningApplication:(Int32)->Application?
        var nextIdentity:(Date)->EventStreamRecordIdentity
        var scheduleLayout:(EventStreamRecordIdentity)->Void
        var makeSelection:(Reference,String)->EventStreamPendingSelectionRecord?
        var enqueueSelection:(EventStreamPendingSelectionRecord)->Void
        var makeTerminal:(Reference,Int32,String?)->EventStreamPendingTerminalRecord<Reference>?
        var storeTerminal:(EventStreamPendingTerminalRecord<Reference>)->Void
    }
    private let backend:Backend
    var shouldCaptureApplication:((Application)->Bool)?
    init(backend:Backend) {self.backend=backend}
    func receive(element:Reference,notification:String,processIdentifier:Int32,bundleIdentifier:String?,timestamp:Date) {
        guard backend.isRecording() else {return}
        if let app=backend.runningApplication(processIdentifier),!(shouldCaptureApplication?(app) ?? true) {return}
        switch notification {
        case "AXFocusedWindowChanged":backend.scheduleLayout(backend.nextIdentity(timestamp))
        case "AXValueChanged":
            if let record=backend.makeTerminal(element,processIdentifier,bundleIdentifier) {backend.storeTerminal(record)}
        default:
            if let record=backend.makeSelection(element,notification) {backend.enqueueSelection(record)}
        }
    }
}

// Ordinary native composition. The complete recorder supplies one shared
// identity source, recording/policy state and the real async window capture.
// This object does not manufacture that capture or install IPC handlers.
@MainActor final class EventStreamNativeRecorderNotifications {
    let sourceOwner:EventStreamNativeSelectionRecordFactory
    private let selection:EventStreamAXNotificationQueue
    private let terminal:EventStreamTerminalValueRecorder<AXUIElement>
    private let layout:EventStreamLayoutNotificationTask
    private let dispatcher:EventStreamRecorderNotificationDispatcher<AXUIElement,NSRunningApplication>
    var shouldCaptureApplication:((NSRunningApplication)->Bool)? {
        get {dispatcher.shouldCaptureApplication}
        set {dispatcher.shouldCaptureApplication=newValue}
    }
    init(sourceOwner:EventStreamNativeSelectionRecordFactory,
         terminalCapture:EventStreamNativeTerminalCapture,
         nextIdentity:@escaping ()->EventStreamRecordIdentity,
         identityAt:@escaping (Date)->EventStreamRecordIdentity,
         isRecording:@escaping ()->Bool,
         runningApplication:@escaping (Int32)->NSRunningApplication? = {NSRunningApplication(processIdentifier:$0)},
         sleep:@escaping (Duration) async throws->Void = {try await ContinuousClock().sleep(for:$0)},
         lifetimeOwner:@escaping ()->AnyObject? = {nil},
         captureWindowChanged:@escaping (EventStreamRecordIdentity) async->Void,
         emit:@escaping (EventStreamRecord)->Void) {
        self.sourceOwner=sourceOwner
        let selection=EventStreamAXNotificationQueue(isRecording:isRecording,sleep:sleep,lifetimeOwner:lifetimeOwner,emit:emit)
        let terminal=EventStreamTerminalValueRecorder<AXUIElement>(nextIdentity:nextIdentity,
            refreshTarget:terminalCapture.refreshTarget,isRecording:isRecording,sleep:sleep,lifetimeOwner:lifetimeOwner,emit:emit)
        let layout=EventStreamLayoutNotificationTask(isRecording:isRecording,sleep:sleep,lifetimeOwner:lifetimeOwner,capture:captureWindowChanged)
        self.selection=selection;self.terminal=terminal;self.layout=layout
        dispatcher = .init(backend:.init(isRecording:isRecording,runningApplication:runningApplication,
            nextIdentity:identityAt,scheduleLayout:layout.schedule,
            makeSelection:{sourceOwner.make(element:$0,notification:$1)},
            enqueueSelection:{selection.enqueue($0.record,key:$0.key,notification:$0.notification)},
            makeTerminal:{terminalCapture.make(element:$0,processIdentifier:$1,bundleIdentifier:$2)},
            storeTerminal:terminal.store))
    }
    func receive(_ event:EventStreamAXNotificationEvent,processIdentifier:Int32,bundleIdentifier:String?,timestamp:Date) {
        dispatcher.receive(element:event.element,notification:event.notification,
            processIdentifier:processIdentifier,bundleIdentifier:bundleIdentifier,timestamp:timestamp)
    }
    func flushTerminal() {terminal.flush()}
    func flushSelection() {selection.flushAfterRecordingGuard()}
    func clearSelectionRecords() {selection.clearPendingRecords()}
    func clearSelectionTaskOwners() {selection.clearScheduledTaskOwners()}
    func cancelPendingTasks() {
        terminal.cancelPendingFlush();layout.cancel();selection.cancelPendingRecords()
    }
    func clearTerminalBuffer() {terminal.clearBuffer()}
}
