import Foundation

// Recorder application transitions.
// The complete recorder owns input, pending buffers, and session boundaries.
@MainActor
final class EventStreamApplicationCaptureController<Application, Observer: AnyObject> {
    struct Backend {
        var isRecording: () -> Bool
        var processIdentifier: (Application) -> Int32
        var nextIdentity: (Date) -> EventStreamRecordIdentity
        var observe: (Application) throws -> Observer?
        var stop: (Observer) -> Void
        var applicationSnapshot: (Application) -> EventStreamApp?
        var captureWindowChanged: (Application, EventStreamRecordIdentity) -> Void
        var emit: (EventStreamRecord) -> Void
        var observationFailed: (Error, Application) -> Void
    }

    var shouldCaptureApplication: ((Application) -> Bool)?
    private let backend: Backend
    private(set) var currentProcessIdentifier: Int32?
    private var observer: Observer?
    var hasObserver: Bool { observer != nil }

    init(backend: Backend) { self.backend = backend }

    func refresh(_ application: Application, at timestamp: Date) {
        guard backend.isRecording() else { return }
        let permitted = shouldCaptureApplication?(application) ?? true
        let pid = backend.processIdentifier(application)
        // Retry an allowed application when observer setup failed, and revisit
        // the same PID when the subscribers' capture policy changes.
        guard currentProcessIdentifier != pid || permitted != hasObserver else { return }
        currentProcessIdentifier = pid
        let identity = backend.nextIdentity(timestamp)
        stopObserver()
        if permitted {
            if pid > 0 {
                do { observer = try backend.observe(application) }
                catch { backend.observationFailed(error, application) }
            }
            // Setup failure does not suppress the initial window capture.
            backend.captureWindowChanged(application, identity)
        } else {
            // A denied application still yields a plain window.changed record;
            // the native metadata helper is permitted to return no application.
            let app = backend.applicationSnapshot(application)
            backend.emit(.init(id: identity.id, timestamp: identity.timestamp,
                               kind: .windowChanged, app: app))
        }
    }

    func stopObserver() {
        if let observer { backend.stop(observer) }
        observer = nil
    }

    // Recorder.stop clears the PID after stopping its AX observer and cancelling
    // pending tasks. These are separate operations to preserve that ordering.
    func clearCurrentApplication() { currentProcessIdentifier = nil }
}
