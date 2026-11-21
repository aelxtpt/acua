import AVFoundation
import ScreenCaptureKit
import os

extension ComputerUseAudioStartRequest {
    func duration() throws -> Int {
        let milliseconds = maxDurationMilliseconds ?? 60_000
        guard (100...300_000).contains(milliseconds) else { throw AudioRecorder.Failure.invalidDuration }
        return milliseconds
    }
}

final class AudioRecorder {
    static let shared = AudioRecorder()
    // Stop schedules removal of the delivered file after 30 seconds.
    static let deliveredFileLifetime: Duration = .seconds(30)
    static let unclaimedRecordingLifetime: Duration = .seconds(30)

    static func retainDeliveredFile(_ url: URL) {
        scheduleDeliveredFileDeletion(url, after: deliveredFileLifetime)
    }

    static func scheduleDeliveredFileDeletion(_ url: URL, after lifetime: Duration) {
        Task.detached {
            do { try await ContinuousClock().sleep(for: lifetime) }
            catch { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // Native XPC exposes these recorder errors through its generic error envelope.
    enum Failure: Error {
        case invalidDuration, noActiveRecording, noDisplay, recordingAlreadyActive, recordingNotOwned

        var socketError: ServiceError {
            ServiceError(.unknownError, "Computer Use server error -10005: \(String(describing: self))")
        }
    }

    typealias StartRequest = ComputerUseAudioStartRequest

    struct Owner {
        let sessionID: String?
        let senderPID: Int32
        let turnID: String?

        init(sessionID: String?, senderPID: Int32, turnID: String? = nil) {
            self.sessionID = sessionID
            self.senderPID = senderPID
            self.turnID = turnID
        }

        func matches(_ other: Owner) -> Bool {
            if let sessionID { return sessionID == other.sessionID }
            return other.sessionID == nil && senderPID == other.senderPID
        }
    }

    private struct Recording {
        let id: UUID
        let url: URL
        let owner: Owner
        var didAutoStop = false
    }

    private let lock = NSLock()
    typealias CaptureFinish = () throws -> Void
    private let startCapture: (URL, @escaping (@escaping CaptureFinish) -> Void) throws -> CaptureFinish
    private let onFileDelivered: (URL) -> Void
    private var recording: Recording?
    // The stream is stored independently of URL/owner metadata.
    // A Stop consumes this handle before awaiting its native callback.
    private var finishCapture: (() throws -> Void)?
    private var autoStop: Task<Void, Never>?

    convenience init() { self.init(prepareCapture: AudioCapture.start) }

    init(onFileDelivered: @escaping (URL) -> Void = AudioRecorder.retainDeliveredFile,
         startCapture: @escaping (URL) throws -> CaptureFinish) {
        self.startCapture = { url, publish in
            let finish = try startCapture(url)
            publish(finish)
            return finish
        }
        self.onFileDelivered = onFileDelivered
    }

    private init(onFileDelivered: @escaping (URL) -> Void = AudioRecorder.retainDeliveredFile,
         prepareCapture: @escaping (URL, @escaping (@escaping CaptureFinish) -> Void) throws -> CaptureFinish) {
        self.startCapture = prepareCapture
        self.onFileDelivered = onFileDelivered
    }

    func start(_ request: StartRequest, owner: Owner) throws {
        try lockForRequest()
        do { try RequestRuntime.check() } catch { lock.unlock(); throw error }
        if let current = recording, current.didAutoStop {
            autoStop?.cancel(); autoStop = nil
            recording = nil
            let finish = finishCapture
            finishCapture = nil
            lock.unlock()
            try? finish?()
            try? FileManager.default.removeItem(at: current.url)
            try lockForRequest()
        }
        let milliseconds: Int
        do {
            guard recording == nil else { throw Failure.recordingAlreadyActive }
            milliseconds = try request.duration()
        } catch { lock.unlock(); throw error }
        let id = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acua-computer-audio-\(id.uuidString).wav")
        // Publish URL/owner before the first framework
        // suspension. Stop, another Start, and turn ending can observe them.
        recording = Recording(id: id, url: url, owner: owner)
        lock.unlock()
        do {
            let finish = try startCapture(url) { finish in
                self.lock.lock()
                self.finishCapture = finish
                self.lock.unlock()
            }
            do { try RequestRuntime.check() }
            catch { try? finish(); throw error }
            lock.lock()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
            autoStop = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                await Self.runBlocking { self.finishAutomatically(id) }
                // Wait another 30 seconds after
                // automatic Stop, then conditionally discards its own URL.
                do { try await ContinuousClock().sleep(for: Self.unclaimedRecordingLifetime) }
                catch { return }
                await Self.runBlocking { self.discardUnclaimedRecording(id) }
            }
            lock.unlock()
        } catch {
            // Setup failures clear current metadata even if a newer
            // pending setup replaced it.
            lock.lock()
            finishCapture = nil
            recording = nil
            lock.unlock()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop(owner: Owner) throws -> URL {
        try lockForRequest()
        let current: Recording
        let finish: (() throws -> Void)?
        do {
            try RequestRuntime.check()
            guard let recording else { throw Failure.noActiveRecording }
            guard recording.owner.matches(owner) else { throw Failure.recordingNotOwned }
            current = recording
            autoStop?.cancel()
            finish = finishCapture
            finishCapture = nil
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        // Preserve actor reentrancy: another Stop can observe the still-owned
        // URL while this one awaits its already-consumed stream.
        // A failed callback leaves current metadata alone.
        try finish?()
        lock.lock()
        recording = nil
        lock.unlock()
        // A successful resume clears URL/owner even if another request
        // replaced them, but do not consume a newly installed stream handle.
        onFileDelivered(current.url)
        return current.url
    }

    func discardEndedTurn(threadID: String, turnID: String?) {
        lock.lock()
        guard let current = recording, current.owner.sessionID == threadID else { lock.unlock(); return }
        if let recordedTurn = current.owner.turnID, let turnID, recordedTurn != turnID { lock.unlock(); return }
        autoStop?.cancel(); autoStop = nil
        recording = nil
        let finish = finishCapture
        finishCapture = nil
        lock.unlock()

        // Cleanup clears metadata before suspension, then removes the
        // captured URL after either callback.
        try? finish?()
        try? FileManager.default.removeItem(at: current.url)
    }

    private func finishAutomatically(_ id: UUID) {
        lock.lock()
        guard recording?.id == id else { lock.unlock(); return }
        let finish = finishCapture
        finishCapture = nil
        lock.unlock()

        // Both callback outcomes reach the same URL identity check.
        try? finish?()
        lock.lock()
        if recording?.id == id { recording?.didAutoStop = true }
        lock.unlock()
    }

    // Timer tasks must yield their cooperative executor while synchronous
    // callback bridges wait, so the recorder suspends at these operations.
    private static func runBlocking(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                continuation.resume()
            }
        }
    }

    private func discardUnclaimedRecording(_ id: UUID) {
        lock.lock()
        guard let current = recording, current.id == id else { lock.unlock(); return }
        autoStop?.cancel(); autoStop = nil
        recording = nil
        let finish = finishCapture
        finishCapture = nil
        lock.unlock()
        try? finish?()
        try? FileManager.default.removeItem(at: current.url)
    }

    private func lockForRequest() throws {
        let limit = ProcessInfo.processInfo.systemUptime + 120
        while !lock.try() {
            try RequestRuntime.check()
            if ProcessInfo.processInfo.systemUptime >= limit {
                throw ServiceError(.unknownError, "Operation timed out")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

/// Owns a single stream and serializes all file access on its sample queue.
private final class AudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "Computer Use")
    // Mutable writer state is confined to sampleQueue after init.
    private let sampleQueue = DispatchQueue(label: "com.aex.computeruse.audio")
    private let url: URL
    private var file: AVAudioFile?
    private var startupPending = true
    private var stopCompleted = false

    private init(url: URL) {
        self.url = url
        super.init()
    }

    private func openWriter() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sampleQueue.async {
                do {
                    let wavFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 2, interleaved: true)!
                    self.file = try AVAudioFile(forWriting: self.url, settings: wavFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func start(at url: URL, prepared: @escaping (@escaping AudioRecorder.CaptureFinish) -> Void) throws -> AudioRecorder.CaptureFinish {
        let capture = AudioCapture(url: url)
        do {
            let bridge = try AudioCaptureBridge.startPrepared(prepare: {
                try await capture.prepareStream()
            }, publish: { bridge in
                prepared { try bridge.stop() }
            }, begin: { stream in
                try await capture.beginCapture(stream)
            }, finish: { stream in
                do { try await stream.stopCapture() }
                catch { await capture.finishedStopping(); throw error }
                await capture.finishedStopping()
            }, abandon: {
                capture.sampleQueue.async { capture.file = nil }
            })
            return { try bridge.stop() }
        } catch {
            capture.sampleQueue.async { capture.file = nil }
            throw error
        }
    }

    private func finishedStopping() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.stopCompleted = true
                if !self.startupPending { self.file = nil }
                continuation.resume()
            }
        }
    }

    private func finishedStarting() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.startupPending = false
                if self.stopCompleted { self.file = nil }
                continuation.resume()
            }
        }
    }

    private func closeWriter() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.file = nil
                continuation.resume()
            }
        }
    }

    private func prepareStream() async throws -> SCStream {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else {
            throw AudioRecorder.Failure.noDisplay
        }
        try await openWriter()
        try Task.checkCancellation()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 24_000
        config.channelCount = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        return stream
    }

    private func beginCapture(_ stream: SCStream) async throws {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
            await finishedStarting()
        } catch {
            await closeWriter()
            throw error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer), let file else { return }
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      let format = AVAudioFormat(standardFormatWithSampleRate: asbd.pointee.mSampleRate, channels: asbd.pointee.mChannelsPerFrame),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer, deallocator: nil) else { return }
                try file.write(from: buffer)
            }
        } catch {
            Self.logger.error("Could not write audio sample: \(String(describing: error), privacy: .private)")
        }
    }
}
