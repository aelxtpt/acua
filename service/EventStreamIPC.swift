import AppKit
import Foundation

// Recording and Timeline use the same capture owner. The
// native producer and its input/AX observers start only when a sink subscribes.
@MainActor enum EventStreamSharedCaptureCoordinator {
    static let shared = EventStreamCaptureCoordinator(recorder: EventStreamNativeRecorderFactory.make())
}

@MainActor final class EventStreamRecordingOwner {
    private static var existing: EventStreamRecordingOwner?
    static var onRecordingStateChanged: (() -> Void)?
    static var onRecordingPolicyChanged: (() -> Void)?
    static var onObservedApplicationsChanged: (() -> Void)?
    static var observedApplications: [EventStreamObservedApplication] {
        existing?.service.processor.observedApplications ?? []
    }
    static var activeBlockedContext: EventStreamBlockedCaptureContext? {
        guard let service = existing?.service, service.isRecording else { return nil }
        return service.processor.blockedCaptureContext
    }
    static var activeRecordingStatus: EventStreamSessionStatus? {
        guard let service = existing?.service, service.isRecording else { return nil }
        return service.status()
    }
    static var activeSessionID: String? { activeRecordingStatus?.sessionID }
    static func stopFromControls(discarded: Bool) -> String? {
        existing?.service.stopFromControls(discarded: discarded)
    }
    static var shared: EventStreamRecordingOwner {
        if let existing { return existing }
        var io = EventStreamRecordingServiceIO()
        io.onStateChanged = { onRecordingStateChanged?() }
        let owner = EventStreamRecordingOwner(io: io)
        owner.service.processor.onBlockedContextChange = { _ in onRecordingPolicyChanged?() }
        owner.service.processor.onObservedApplicationsChange = { _ in onObservedApplicationsChanged?() }
        existing = owner
        return owner
    }
    static func stopIfLoaded() { _ = existing?.service.stop(reason: .serviceTerminated) }

    let coordinator: EventStreamCaptureCoordinator<EventStreamNativeRecorder>
    let service: EventStreamRecordingService<EventStreamNativeRecorder>

    // Explicit dependencies let disposable fixtures scope native capture and
    // storage. Normal construction always uses the shared native coordinator,
    // authenticated URL checker and configured application-group container.
    init(coordinator: EventStreamCaptureCoordinator<EventStreamNativeRecorder>? = nil,
         rootDirectoryURL: URL? = nil, maximumDurationSeconds: Int = 1800,
         io: EventStreamRecordingServiceIO? = nil,
         shouldCaptureApplication: @escaping (NSRunningApplication) -> Bool = { _ in true }) {
        let coordinator = coordinator ?? EventStreamSharedCaptureCoordinator.shared
        let applications = EventStreamApplicationResolver()
        let policy = EventStreamRecordingURLPolicy.local()
        self.coordinator = coordinator
        service = EventStreamRecordingService(coordinator: coordinator,
            rootDirectoryURL: rootDirectoryURL, maximumDurationSeconds: maximumDurationSeconds,
            filter: policy.makeRecordFilter(resolver: applications),
            resolveApplication: applications.resolve, io: io,
            shouldCaptureApplication: shouldCaptureApplication)
    }
}

enum EventStreamIPC {
    private enum Operation { case start, status, stop(EventStreamEndReason) }

    static func perform(requestType: String, request: Any, preserveDecodingError: Bool = false,
        owner: @escaping @MainActor () -> EventStreamRecordingOwner = { .shared }) throws -> JSON {
        let operation: Operation
        do {
            let bytes = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
            switch requestType {
            case "ComputerUseIPCEventStreamStartRequest":
                _ = try JSONDecoder().decode(EventStreamStartRequest.self, from: bytes)
                operation = .start
            case "ComputerUseIPCEventStreamStatusRequest":
                _ = try JSONDecoder().decode(EventStreamStatusRequest.self, from: bytes)
                operation = .status
            case "ComputerUseIPCEventStreamStopRequest":
                operation = .stop(try JSONDecoder().decode(EventStreamStopRequest.self, from: bytes).reason)
            default:
                throw ServiceError(.couldNotResolveRequestType, "Unsupported request type '\(requestType)'")
            }
        } catch let error as ServiceError { throw error }
        catch {
            if preserveDecodingError { throw error }
            throw ServiceError(.couldNotGetRequestData, "Could not decode \(requestType)")
        }

        let metadata = ComputerUseTelemetryContext.snapshot()
        let scope = RequestRuntime.workerScope()
        let execute: @MainActor () throws -> Data = {
            try ComputerUseTelemetryContext.$current.withValue(metadata) {
                try RequestRuntime.withWorkerScope(scope, cancelled: { Task.isCancelled }) {
                    try RequestRuntime.check()
                    let service = owner().service
                    let result: EventStreamSessionStatus
                    switch operation {
                    case .start:
                        // This is the snapshot's session ID,
                        // not a guessed thread/turn key or an empty fallback.
                        result = try service.start(originatingThreadID: ComputerUseTelemetryContext.snapshot().agentSessionID)
                    case .status: result = service.status()
                    case .stop(let reason): result = service.stop(reason: reason)
                    }
                    // The RPC encoder uses reference-epoch numeric dates.
                    // JSONL/metadata storage separately uses ISO8601 dates.
                    return try JSONEncoder().encode(result)
                }
            }
        }
        let data: Data
        if Thread.isMainThread {
            data = try MainActor.assumeIsolated { try execute() }
        } else {
            let pending = PendingResult<Data>(discard: { _ in })
            let task = Task { @MainActor in
                do { try Task.checkCancellation(); pending.complete(.success(try execute())) }
                catch { pending.complete(.failure(error)) }
            }
            do {
                try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
                data = try pending.take()
            } catch {
                task.cancel()
                pending.abandon()
                throw error
            }
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw ServiceError(.unknownError, "Event stream returned an invalid status")
        }
        return value
    }

    static func shutdownIfLoaded() {
        if Thread.isMainThread { MainActor.assumeIsolated { EventStreamRecordingOwner.stopIfLoaded() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { EventStreamRecordingOwner.stopIfLoaded() } } }
    }
}
