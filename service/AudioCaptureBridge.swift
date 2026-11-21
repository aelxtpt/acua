import Foundation

/// Adapts the native asynchronous stream to the synchronous request worker.
/// Timed-out starts dispose late streams. A native stop remains owned until its
/// callback completes; the recorder makes separate, reentrant claims of
/// URL/owner metadata.
final class AudioCaptureBridge<Resource>: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var outcome: Result<Void, Error>?
        private var failureReported = false

        init() { group.enter() }

        func complete(_ result: Result<Void, Error>) {
            lock.lock(); outcome = result; lock.unlock()
            group.leave()
        }

        func wait() throws {
            let limit = ProcessInfo.processInfo.systemUptime + 120
            while true {
                try RequestRuntime.check()
                if group.wait(timeout: .now() + 0.01) == .success { break }
                if ProcessInfo.processInfo.systemUptime >= limit {
                    throw ServiceError(.unknownError, "Operation timed out")
                }
            }
            try RequestRuntime.check()
            lock.lock()
            let failure: Error?
            if case .failure(let error) = outcome, !failureReported {
                failureReported = true
                failure = error
            } else { failure = nil }
            lock.unlock()
            // Stop consumes the stream before awaiting its callback.
            // After its first error a retry can claim the closed file without
            // issuing another native stop.
            if let failure { throw failure }
        }
    }

    private let lock = NSLock()
    private var resource: Resource?
    private let finish: (Resource) async throws -> Void
    private let abandon: () -> Void
    private var completion: Completion?
    private var abandonmentReported = false
    private let finishOnDeinit: Bool

    private init(_ resource: Resource, finish: @escaping (Resource) async throws -> Void,
                 abandon: @escaping () -> Void, finishOnDeinit: Bool = true) {
        self.finishOnDeinit = finishOnDeinit
        self.resource = resource
        self.finish = finish
        self.abandon = abandon
    }

    deinit {
        // Legacy adapters transfer an unclaimed resource to asynchronous
        // cleanup. Prepared native owners instead release their SDK object,
        // matching CaptureStream destruction without an extra stop call.
        if let resource {
            let finish = finish
            abandon()
            if finishOnDeinit { Task { try? await finish(resource) } }
        }
    }

    static func start(begin: @escaping () async throws -> Resource,
                      finish: @escaping (Resource) async throws -> Void,
                      abandon: @escaping () -> Void = {}) throws -> AudioCaptureBridge {
        try RequestRuntime.check()
        let pending = PendingResult<Resource>(discard: { value in
            Task { try? await finish(value) }
        })
        let task = Task {
            do { pending.complete(.success(try await begin())) }
            catch { pending.complete(.failure(error)) }
        }
        do {
            try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
            return AudioCaptureBridge(try pending.take(), finish: finish, abandon: abandon)
        } catch {
            task.cancel()
            abandon()
            pending.abandon()
            throw error
        }
    }

    private final class Abandonment: @unchecked Sendable {
        private let lock = NSLock()
        private var notified = false
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func notify() {
            lock.lock()
            let notify = !notified
            notified = true
            lock.unlock()
            if notify { action() }
        }
    }

    private final class PreparedStart: @unchecked Sendable {
        private let lock = NSLock()
        private var abandoned = false
        private var bridge: AudioCaptureBridge?
        private let abandonment: Abandonment
        init(_ abandonment: Abandonment) { self.abandonment = abandonment }

        func publish(_ value: AudioCaptureBridge, using publish: (AudioCaptureBridge) -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !abandoned else { return false }
            bridge = value
            // The callback only installs the recorder handle. Serializing it
            // with abandon prevents publication after the caller has expired.
            publish(value)
            return true
        }

        func abandon() {
            lock.lock()
            guard !abandoned else { lock.unlock(); return }
            abandoned = true
            let value = bridge
            lock.unlock()
            abandonment.notify()
            if let value { Task { try? value.stop() } }
        }
    }

    /// Publishes native ownership before awaiting the SDK start callback.
    /// Normal native release drops the SDK object as CaptureStream does; only
    /// an explicit Stop or an abandoned request issues an SDK stop operation.
    static func startPrepared(prepare: @escaping () async throws -> Resource,
                              publish: @escaping (AudioCaptureBridge) -> Void,
                              begin: @escaping (Resource) async throws -> Void,
                              finish: @escaping (Resource) async throws -> Void,
                              abandon: @escaping () -> Void = {}) throws -> AudioCaptureBridge {
        try RequestRuntime.check()
        let abandonment = Abandonment(abandon)
        let state = PreparedStart(abandonment)
        let pending = PendingResult<AudioCaptureBridge>(discard: { _ in })
        let task = Task {
            do {
                let resource = try await prepare()
                let bridge = AudioCaptureBridge(resource, finish: finish,
                    abandon: abandonment.notify, finishOnDeinit: false)
                guard state.publish(bridge, using: publish) else {
                    // A late prepared resource belongs to cleanup, never to a
                    // later recording that may now occupy the same recorder.
                    Task { try? bridge.stop() }
                    return
                }
                try Task.checkCancellation()
                try await begin(resource)
                pending.complete(.success(bridge))
            } catch { pending.complete(.failure(error)) }
        }
        do { try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120) }
        catch {
            task.cancel()
            state.abandon()
            pending.abandon()
            throw error
        }
        // A native start error drops the published SDK owner in the recorder's
        // cleanup path; it does not issue an extra stop.
        return try pending.take()
    }

    func stop() throws {
        lock.lock()
        let ending: Completion
        if let completion { ending = completion }
        else {
            ending = Completion()
            completion = ending
            let value = resource!
            resource = nil
            let finish = finish
            Task {
                do { try await finish(value); ending.complete(.success(())) }
                catch { ending.complete(.failure(error)) }
            }
        }
        lock.unlock()
        // Start cleanup even when the initiating scope just expired.
        do { try ending.wait() }
        catch {
            lock.lock()
            let notify = !abandonmentReported
            abandonmentReported = true
            lock.unlock()
            if notify { abandon() }
            throw error
        }
    }
}
