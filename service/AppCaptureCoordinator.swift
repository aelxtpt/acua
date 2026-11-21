import Foundation
import CoreGraphics

struct AppshotPermissionCache {
    private var abandoned: [String: AppCaptureWire.PermissionState] = [:]

    subscript(id: String) -> AppCaptureWire.PermissionState? { abandoned[id] }

    mutating func recordDismissal(ids: [String], state: AppCaptureWire.PermissionState) {
        guard state != .both else { return }
        for id in ids { abandoned[id] = state }
    }
}

struct AppshotPermissionSettingsVisits {
    enum Permission: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"

        var settingsURL: URL? {
            try? SystemSettings.url(for: self == .accessibility ? .privacyAccessibility : .privacyScreenCapture)
        }
    }

    private var active: (permission: Permission, id: UUID)?

    var isEmpty: Bool { active == nil }

    func isCurrent(_ permission: Permission, id: UUID) -> Bool { active?.permission == permission && active?.id == id }

    mutating func begin(_ permission: Permission) -> UUID? {
        guard active == nil else { return nil }
        let id = UUID()
        active = (permission, id)
        return id
    }

    mutating func failedToOpen(_ permission: Permission, id: UUID) {
        if isCurrent(permission, id: id) { active = nil }
    }

    mutating func granted(_ permission: Permission) {
        if active?.permission == permission { active = nil }
    }

    mutating func end() { active = nil }
}

enum AppshotPermissionAccessoryLayout {
    static func qualifies(_ window: CGRect) -> Bool {
        window.minX.isFinite && window.minY.isFinite && window.maxX.isFinite && window.maxY.isFinite &&
        window.width > 600 && window.height >= 470
    }

    static func settingsFrame(_ window: CGRect, primaryScreenHeight: CGFloat) -> CGRect? {
        guard primaryScreenHeight.isFinite, primaryScreenHeight > 0, qualifies(window) else { return nil }
        return CGRect(x: window.minX, y: primaryScreenHeight - window.maxY,
                      width: window.width, height: window.height)
    }

    static func accessoryFrame(in settings: CGRect, size: CGSize, audioHeadingOffset: CGFloat? = nil) -> CGRect {
        var bottom = settings.minY
        if let offset = audioHeadingOffset, offset.isFinite {
            bottom = max(bottom, settings.maxY - offset - size.height)
        }
        return CGRect(x: settings.maxX - size.width - 10, y: bottom + 10,
                      width: size.width, height: size.height).integral
    }

    static func audioHeading<Node>(in children: [Node], role: String, readRole: (Node) -> String?) -> Node? {
        var count = 0
        for child in children where readRole(child) == role {
            count += 1
            if count == 3 { return child }
        }
        return nil
    }
}

struct AppshotPermissionAccessoryTracking {
    enum Action { case show, hide, returnToPermissions }

    private let firstWindowDeadline: ContinuousClock.Instant
    private var sawWindow = false
    private var presented = false

    init(startedAt: ContinuousClock.Instant = .now) {
        firstWindowDeadline = startedAt + .seconds(5)
    }

    static func needsEarlyActivation(hasWindows: Bool, hasVisibleMainWindow: Bool) -> Bool {
        hasWindows && !hasVisibleMainWindow
    }

    mutating func didPresent() -> Bool {
        let first = !presented
        presented = true
        return first
    }

    mutating func update(windowExists: Bool?, active: Bool, terminated: Bool,
                         at time: ContinuousClock.Instant = .now) -> Action {
        if terminated || (sawWindow && windowExists == false) { return .returnToPermissions }
        if windowExists == true {
            sawWindow = true
            return !presented || active ? .show : .hide
        }
        if !sawWindow && time >= firstWindowDeadline { return .returnToPermissions }
        return .hide
    }
}

struct AppshotSettingsGrantCheck {
    enum Action { case wait, validated, finish }

    private enum Phase {
        case beforeDrop
        case afterDrop(until: ContinuousClock.Instant)
        case dialogs(after: ContinuousClock.Instant, until: ContinuousClock.Instant)
    }

    private var phase = Phase.beforeDrop

    mutating func dropped(at time: ContinuousClock.Instant) {
        if case .beforeDrop = phase { phase = .afterDrop(until: time + .seconds(120)) }
    }

    mutating func update(at time: ContinuousClock.Instant, authorized: @autoclosure () -> Bool,
                         dialogsDismissed: @autoclosure () -> Bool) -> Action {
        switch phase {
        case .dialogs(let after, let until):
            return time >= until || (time >= after && dialogsDismissed()) ? .finish : .wait
        case .beforeDrop, .afterDrop:
            if authorized() {
                let after = time + .milliseconds(500)
                phase = .dialogs(after: after, until: after + .seconds(120))
                return .validated
            }
            if case .afterDrop(let until) = phase, time >= until { return .finish }
            return .wait
        }
    }
}

struct AppshotPermissionWaiters<Reply> {
    private struct Entry {
        let id: String
        let reply: Reply
        let deadline: ContinuousClock.Instant
    }

    private var active: [UUID: Entry] = [:]
    private var timedOutIDs = Set<String>()

    var isEmpty: Bool { active.isEmpty && timedOutIDs.isEmpty }
    var dismissalIDs: [String] { Array(timedOutIDs) + active.values.map(\.id) }

    mutating func insert(_ token: UUID, id: String, reply: Reply, at time: ContinuousClock.Instant) {
        active[token] = Entry(id: id, reply: reply, deadline: time + .seconds(110))
    }

    mutating func expire(at time: ContinuousClock.Instant) -> [Reply] {
        let expired = active.filter { $0.value.deadline <= time }
        for (token, entry) in expired {
            active.removeValue(forKey: token)
            timedOutIDs.insert(entry.id)
        }
        return expired.values.map(\.reply)
    }

    mutating func cancel(_ token: UUID) { active.removeValue(forKey: token) }

    mutating func drain() -> [Reply] {
        let pending = active.values.map(\.reply)
        active.removeAll()
        timedOutIDs.removeAll()
        return pending
    }
}

/// An unconsumed file is removed when its last stage/producer reference dies.
/// A successfully delivered URL transfers file ownership to the caller.
final class CaptureFileLease {
    let url: URL
    private let lock = NSLock()
    private var published = false
    private let remove: (URL) -> Void
    init(url: URL, remove: @escaping (URL) -> Void) { self.url = url; self.remove = remove }
    func didPublish() { lock.lock(); published = true; lock.unlock() }
    deinit { if !published { remove(url) } }
}

final class AppCaptureCoordinator {
    enum CaptureFailure: Error { case blockedByPolicy, screenshot, unknown }
    enum Preparation { case ready(Plan), abandoned(AppCaptureWire.PermissionState) }
    struct Plan {
        let app: IPCApp
        var response = AppCaptureWire.StartResponse(result: .started)
        let run: (Emitter) throws -> Void
        var cancel: () -> Void = {}
        var complete: (() -> Void)? = nil
    }
    fileprivate struct Stage { let update: AppCaptureWire.Update; let file: CaptureFileLease? }
    fileprivate final class Job {
        private let lock = NSLock()
        private var cancelled = false
        private var succeeded = false
        let cleanup, completed: () -> Void
        init(cleanup: @escaping () -> Void, completed: @escaping () -> Void) { self.cleanup = cleanup; self.completed = completed }
        func markSucceeded() { lock.lock(); succeeded = true; lock.unlock() }
        func retire(_ reason: AppCaptureStore<Stage>.Retirement) {
            lock.lock(); let first = !cancelled; cancelled = true; let success = succeeded; lock.unlock()
            if first { if reason == .consumed && success { completed() } else { cleanup() } }
        }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); let first = !cancelled; cancelled = true; lock.unlock()
            if first { cleanup() }
        }
    }
    final class Emitter {
        private let lock = NSLock()
        private var finished = false
        private var finalSnapshot: CaptureFileLease?
        private let app: IPCApp
        private let job: Job
        private let store: AppCaptureStore<Stage>
        private let token: AppCaptureStore<Stage>.Token
        fileprivate init(app: IPCApp, job: Job, store: AppCaptureStore<Stage>, token: AppCaptureStore<Stage>.Token) {
            self.app = app; self.job = job; self.store = store; self.token = token
        }
        func check() throws {
            if job.isCancelled { throw ServiceError(.unknownError, "Capture was cancelled") }
            try RequestRuntime.check()
        }
        var isCancelled: Bool { job.isCancelled }
        private func send(_ update: AppCaptureWire.Update, file: CaptureFileLease? = nil, terminal: Bool = false) throws {
            try check()
            lock.lock(); defer { lock.unlock() }
            guard !finished else { throw ServiceError(.unknownError, "Capture already finished") }
            if terminal && update.type == .completed { job.markSucceeded() }
            try store.publish(Stage(update: update, file: file), token: token, terminal: terminal)
            finished = terminal
        }
        fileprivate func metadata() throws { try send(.init(type: .metadata, app: app)) }
        func text(_ text: String) throws { try send(.init(type: .axText, app: app, text: text)) }
        func screenshot(_ file: CaptureFileLease, mimeType: String = "image/jpeg") throws {
            try send(.init(type: .screenshot, app: app, screenshot: .init(url: file.url, mimeType: mimeType)), file: file)
        }
        func terminalFrame(_ file: CaptureFileLease?) { lock.lock(); finalSnapshot = file; lock.unlock() }
        func finalFrame(_ file: CaptureFileLease?) throws {
            terminalFrame(file)
            try send(.init(type: .screenshot, app: app, transitionSnapshotURL: file?.url), file: file)
        }
        fileprivate func complete() throws {
            lock.lock(); let file = finalSnapshot; lock.unlock()
            try send(.init(type: .completed, app: app, transitionSnapshotURL: file?.url), file: file, terminal: true)
        }
        fileprivate func fail(_ reason: AppCaptureWire.FailureReason) throws {
            try send(.init(type: .failed, app: app, failureReason: reason), terminal: true)
        }
    }
    private let store: AppCaptureStore<Stage>
    private let prepare: (AppCaptureWire.Start) throws -> Preparation
    init(terminalRetention: TimeInterval = 30, prepare: @escaping (AppCaptureWire.Start) throws -> Preparation) {
        self.prepare = prepare; self.store = AppCaptureStore(terminalRetention: terminalRetention)
    }

    func start(_ request: JSON, checkPermissions: ((AppCaptureWire.Start) throws -> AppCaptureWire.PermissionState?)? = nil) throws -> JSON {
        let decoded = try Self.decode(AppCaptureWire.Start.self, request)
        try RequestRuntime.check()
        if let checkPermissions {
            let state = try checkPermissions(decoded)
            try RequestRuntime.check()
            if let state {
                return try Self.json(AppCaptureWire.StartResponse(result: .permissionsAbandoned, permissionGrantState: state))
            }
        }
        switch try prepare(decoded) {
        case .abandoned(let state):
            return try Self.json(AppCaptureWire.StartResponse(result: .permissionsAbandoned, permissionGrantState: state))
        case .ready(let plan):
            let response: JSON
            do { response = try Self.json(plan.response) }
            catch { plan.cancel(); throw error }
            let job = Job(cleanup: plan.cancel, completed: plan.complete ?? plan.cancel)
            let token: AppCaptureStore<Stage>.Token
            do {
                try RequestRuntime.check()
                token = try store.begin(requestID: decoded.requestID, onRetire: job.retire)
            }
            catch { job.cancel(); throw Self.serviceError(error) }
            let scope = RequestRuntime.workerScope()
            let emitter = Emitter(app: plan.app, job: job, store: store, token: token)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try RequestRuntime.withWorkerScope(scope, cancelled: { job.isCancelled }) {
                        try emitter.metadata()
                        try plan.run(emitter)
                    }
                    try emitter.complete()
                } catch {
                    guard !job.isCancelled else { return }
                    let reason: AppCaptureWire.FailureReason
                    switch error {
                    case CaptureFailure.blockedByPolicy: reason = .blockedByPolicy
                    case CaptureFailure.screenshot: reason = .screenshotCaptureFailed
                    case let e as ServiceError where e.code == .appNotAllowed || e.code == .blockedURL: reason = .blockedByPolicy
                    default: reason = .unknownCaptureFailed
                    }
                    // Outside the worker scope, an expired deadline can still
                    // produce the failure stage for a later Next request.
                    do { try emitter.fail(reason) }
                    catch { store.remove(token) }
                }
            }
            return response
        }
    }

    func next(_ request: JSON) throws -> JSON {
        let decoded = try Self.decode(AppCaptureWire.Next.self, request)
        do {
            let delivery = try store.next(requestID: decoded.requestID, check: RequestRuntime.check)
            let result = try Self.json(delivery.value.update)
            try RequestRuntime.check()
            if ResponseDelivery.reserve(commit: {
                // The bytes are already written. Retain a delivered file even
                // if this generation was replaced during transport.
                delivery.value.file?.didPublish()
                try? delivery.commit()
            }, abandon: { delivery.abandon() }) { return result }
            // Direct in-process callers have no transport owner.
            try delivery.commit(check: RequestRuntime.check)
            delivery.value.file?.didPublish()
            return result
        } catch { throw Self.serviceError(error) }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ request: JSON) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: request)) }
        catch { throw ServiceError(.couldNotGetRequestData, "Invalid capture request") }
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSON {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? JSON else {
            throw ServiceError(.unknownError, "Could not encode capture response")
        }
        return result
    }
    private static func serviceError(_ error: Error) -> Error {
        if let e = error as? ServiceError { return e }
        if let e = error as? AppCaptureStore<Stage>.StoreError {
            switch e {
            case .missing, .replaced: return ServiceError(.unknownError, "Capture request is no longer available")
            case .readerBusy: return ServiceError(.unknownError, "Another request is delivering this capture update")
            case .readerSuperseded: return ServiceError(.unknownError, "A newer request is waiting for this capture")
            case .full: return ServiceError(.unknownError, "Too many capture requests are pending")
            case .finished: return ServiceError(.unknownError, "Capture already finished")
            case .timedOut: return ServiceError(.unknownError, "Capture update timed out")
            }
        }
        return error
    }
}
