import AppKit
import Combine
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox
import XPC

@MainActor private final class OwnedStream: RemoteHostedPIPPublishingStream {
    let presentationID = "owned"
    var isPublished = false, isInvalidated = false, videoEnabled = false
    var maxDisplaySize: CGFloat = 200
    var maxVideoPixelDimension = 720
    var resets = 0, cancellations = 0
    var actions = [String]()
    func resetHostState() { resets += 1; isPublished = false; videoEnabled = false }
    func publish(to connection: NSXPCConnection) async throws { isPublished = true }
    func updateMaxDisplaySize(_ size: CGFloat, connection: NSXPCConnection?) async throws { maxDisplaySize = size }
    func performAction(_ action: RemoteHostedPIPContentAction) {
        switch action {
        case .custom(let value):
            actions.append(value)
            if value == "dom-video-start" { videoEnabled = true }
            if value == "dom-video-stop" { videoEnabled = false }
        case .focusPresentation: actions.append("focus")
        }
    }
    func cancelEndStreamTimeout() { cancellations += 1 }
}

private enum QueueContext { @TaskLocal static var value: String = "none" }
private final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }

@main @MainActor private enum Tests {
    static var checks = 0
    static var observedQueue = [String: Any]()
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        checks += 1; print("PASS: \(label)")
    }
    static func state(_ owner: RemoteHostedPIPContentPublisher, _ stream: OwnedStream) -> [String: Any] {
        ["publisherDisplayBits": String(Double(owner.maxDisplaySize).bitPattern), "streamDisplayBits": String(Double(stream.maxDisplaySize).bitPattern),
            "videoDimension": stream.maxVideoPixelDimension, "videoEnabled": stream.videoEnabled, "published": stream.isPublished,
            "invalidated": stream.isInvalidated, "activeCount": owner.streamsByPresentationID.count, "endingCount": owner.endingStreamsByPresentationID.count]
    }
    static func errorValue(_ error: NSError?) -> Any {
        error.map { ["domain": $0.domain.replacingOccurrences(of: #"\$[0-9a-fA-F]+"#, with: "$<context>", options: .regularExpression),
            "code": $0.code, "userInfo": $0.userInfo] as [String: Any] } ?? NSNull()
    }
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
    static func compareWithCorpus(_ corpus: [String: Any]) async -> [[String: Any]] {
        let owner = RemoteHostedPIPContentPublisher(), stream = OwnedStream()
        owner.registerExistingStream(stream)
        var results = [[String: Any]]()
        for expected in corpus["cases"] as! [[String: Any]] {
            let name = expected["name"] as! String, arguments = expected["arguments"] as! [String: Any], before = state(owner, stream)
            var replies = 0; var error: NSError?
            let done: RemoteHostedPIPReply = { replies += 1; error = $0 }
            let id = arguments["presentation"] as? String == "missing" ? "owned-missing" : "owned"
            if name.hasPrefix("display-") { owner.setMaxDisplaySize(Double(bitPattern: UInt64(arguments["bits"] as! String)!), reply: done) }
            else if name.hasPrefix("video-") { owner.setVideoMaxPixelDimension(Double(bitPattern: UInt64(arguments["bits"] as! String)!), presentationID: id, reply: done) }
            else if name.hasPrefix("action-") { owner.performAction(presentationID: id, kind: arguments["kind"] as! String, reply: done) }
            else if name.hasPrefix("end-") { owner.didEndStream(presentationID: id, reply: done) }
            else if name.hasPrefix("pet-") {
                owner.setPetLocation(x: Double(bitPattern: UInt64(arguments["xBits"] as! String)!), y: Double(bitPattern: UInt64(arguments["yBits"] as! String)!), available: arguments["available"] as! Bool, reply: done)
            } else { fatalError("Unknown corpus case") }
            let immediate = replies
            guard await waitUntil({ replies != 0 }) else { fatalError("Missing producer reply") }
            if name.hasPrefix("display-") {
                guard await waitUntil({ owner.maxDisplaySize == stream.maxDisplaySize }) else { fatalError("Missing queued size update") }
            }
            var result: [String: Any] = ["name": name, "arguments": arguments, "before": before, "after": state(owner, stream), "immediateReplies": immediate, "replies": replies, "error": errorValue(error)]
            if name.hasPrefix("pet-") {
                let point = RemoteHostedPIPPetLocation.position
                result["petState"] = ["absent": point == nil ? 1 : 0, "xBits": String(Double(point?.x ?? 0).bitPattern), "yBits": String(Double(point?.y ?? 0).bitPattern)]
            }
            if !NSDictionary(dictionary: expected).isEqual(to: result) {
                fputs("Expected: \(expected)\nActual: \(result)\n", stderr)
            }
            check(NSDictionary(dictionary: expected).isEqual(to: result), "producer command matches \(name)")
            results.append(result)
        }
        return results
    }

    static func queueChecks(_ corpus: [String: Any]) async {
        let queue = AsyncSerialQueue()
        var events = [String](), release: CheckedContinuation<Void, Never>?
        queue.async { @MainActor in
            events.append("first-start")
            await withCheckedContinuation { release = $0 }
            events.append("first-end")
        }
        queue.async { @MainActor in events.append("second") }
        guard await waitUntil({ release != nil }) else { fatalError("Queue worker missing") }
        for _ in 0..<10 { await Task.yield() }
        check(events == ["first-start"], "serial queue awaits a suspended job before starting the next")
        release!.resume(); release = nil
        guard await waitUntil({ events.count == 3 }) else { fatalError("Queue did not resume") }
        check(events == ["first-start", "first-end", "second"], "serial queue resumes buffered jobs in FIFO order")
        var reentrant = [Int]()
        queue.async { @MainActor in
            reentrant.append(1)
            queue.async { @MainActor in reentrant.append(3) }
        }
        queue.async { @MainActor in reentrant.append(2) }
        guard await waitUntil({ reentrant.count == 3 }) else { fatalError("Reentrant queue stalled") }
        check(reentrant == [1,2,3], "reentrant submission appends behind already-buffered work")
        let contextual = QueueContext.$value.withValue("initializer") { AsyncSerialQueue() }
        var local = "pending"
        QueueContext.$value.withValue("submitter") { contextual.async { @MainActor in local = QueueContext.value } }
        guard await waitUntil({ local != "pending" }) else { fatalError("Context job missing") }
        check(local == "initializer", "worker inherits initializer task locals rather than submitter locals")
        var cancellable: AsyncSerialQueue? = AsyncSerialQueue()
        let weakQueue = WeakReference(cancellable)
        var gate: CheckedContinuation<Void, Never>?, finished = false, cancelled = false, bufferedRan = false
        var cancellationEvents = [String]()
        cancellable!.async { @MainActor in
            cancellationEvents.append("first-start")
            await withCheckedContinuation { gate = $0 }
            cancelled = Task.isCancelled
            cancellationEvents.append(cancelled ? "cancelled" : "not-cancelled")
            cancellationEvents.append("first-end"); finished = true
        }
        cancellable!.async { @MainActor in cancellationEvents.append("buffered"); bufferedRan = true }
        guard await waitUntil({ gate != nil }) else { fatalError("Cancellation job missing") }
        let beforeCancellation = cancellationEvents
        cancellable = nil
        check(weakQueue.value == nil, "queue worker does not retain its owner while an operation is suspended")
        gate!.resume(); gate = nil
        guard await waitUntil({ finished }) else { fatalError("Cancelled queue operation did not finish") }
        check(cancelled, "queue destruction cancels the running worker task")
        guard await waitUntil({ bufferedRan }) else { fatalError("Buffered work did not run") }
        check(bufferedRan, "finished queue still runs already-buffered work")
        let observed: [String: Any] = ["before": beforeCancellation, "after": cancellationEvents, "queueReleased": weakQueue.value == nil]
        observedQueue = observed
        check(NSDictionary(dictionary: corpus["queue"] as! [String: Any]).isEqual(to: observed), "queue cancellation and buffered-job trace matches")
    }

    static func lifetimeChecks() async {
        var owner: RemoteHostedPIPContentPublisher? = RemoteHostedPIPContentPublisher()
        let released = WeakReference(owner)
        var replies = 0, errors = 0
        let done: RemoteHostedPIPReply = { if $0 != nil { errors += 1 }; replies += 1 }
        owner!.connect(reply: done)
        owner!.setMaxDisplaySize(.nan, reply: done)
        owner!.setVideoMaxPixelDimension(.nan, presentationID: "missing", reply: done)
        owner!.performAction(presentationID: "missing", kind: "owned", reply: done)
        owner!.didEndStream(presentationID: "missing", reply: done)
        owner!.setPetLocation(x: 34, y: 56, available: true, reply: done)
        owner = nil
        check(released.value == nil && replies == 1, "queued producer commands do not keep a released publisher alive")
        guard await waitUntil({ replies == 6 }) else { fatalError("Missing released-owner reply") }
        check(errors == 0, "released-owner commands keep the nil-error acknowledgement")
        check(RemoteHostedPIPPetLocation.position == CGPoint(x: 34, y: 56), "pet update survives publisher release because it belongs to shared state")
        RemoteHostedPIPPetLocation.clear()
        let registry = RemoteHostedPIPContentPublisher(), old = OwnedStream(), replacement = OwnedStream()
        registry.registerExistingStream(old); registry.registerExistingStream(replacement)
        registry.registerExistingEndingStream(old)
        check(registry.streamsByPresentationID["owned"] === replacement && registry.endingStreamsByPresentationID.isEmpty,
            "stale stream identity cannot move its replacement into the ending registry")
        replacement.isInvalidated = true; registry.registerExistingEndingStream(replacement)
        check(registry.streamsByPresentationID.isEmpty && registry.endingStreamsByPresentationID["owned"] === replacement,
            "only the identical active stream moves into the ending registry")
    }

    static func main() async throws {
        if Bundle.main.bundleIdentifier?.hasSuffix(".child") == true { runOwnedChild(); return }
        let packaged = Bundle.main.bundleIdentifier != nil
        let corpusPath = CommandLine.arguments[packaged ? 2 : 1]
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: corpusPath))) as! [String: Any]
        let results = await compareWithCorpus(corpus)
        await queueChecks(corpus)
        await lifetimeChecks()
        if packaged {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            try JSONSerialization.data(withJSONObject: results, options: .sortedKeys).write(to: directory.appendingPathComponent("producer-results.json"))
            try JSONSerialization.data(withJSONObject: observedQueue, options: .sortedKeys).write(to: directory.appendingPathComponent("queue-result.json"))
            await nativeChecks(directory)
        } else if CommandLine.arguments.count > 2 {
            try JSONSerialization.data(withJSONObject: results, options: .sortedKeys).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("Native PIP producer checks: \(checks)")
    }
}

@objc(OwnedPIPProducerBootstrap) private protocol BootstrapProtocol {
    func endpoint(reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void)
    func snapshot(reply: @escaping (Data) -> Void)
    func cursor(_ x: Double, y: Double, active: Bool, reply: @escaping () -> Void)
    func cursorBurst(reply: @escaping () -> Void)
    func markEnding(reply: @escaping () -> Void)
    func startCheckerboard(thread: String, reply: @escaping (String) -> Void)
    func endCheckerboard(_ id: String, reply: @escaping () -> Void)
    func retry(reply: @escaping () -> Void)
    func shutdown(reply: @escaping () -> Void)
}

@MainActor private final class Bootstrap: NSObject, BootstrapProtocol {
    let publisher = RemoteHostedPIPContentPublisher(), stream = OwnedStream()
    override init() { super.init(); publisher.registerExistingStream(stream) }
    nonisolated func endpoint(reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void) {
        Task { @MainActor in reply(self.publisher.endpointForHostConnection(), getpid()) }
    }
    nonisolated func snapshot(reply: @escaping (Data) -> Void) {
        Task { @MainActor in
            var value = Tests.state(self.publisher, self.stream)
            let location = RemoteHostedPIPPetLocation.position
            value["petPresent"] = location != nil
            value["petXBits"] = String(Double(location?.x ?? 0).bitPattern)
            value["petYBits"] = String(Double(location?.y ?? 0).bitPattern)
            value["actions"] = self.stream.actions; value["cancellations"] = self.stream.cancellations
            value["resets"] = self.stream.resets; value["status"] = String(describing: self.publisher.connectionDiagnostics.status)
            value["publishedNativeIDs"] = self.publisher.streamsByPresentationID.values
                .filter { $0 is RemoteHostedPIPContentStream && $0.isPublished }.map(\.presentationID).sorted()
            value["endingNativeIDs"] = self.publisher.endingStreamsByPresentationID.values
                .filter { $0 is RemoteHostedPIPContentStream }.map(\.presentationID).sorted()
            value["diagnosticMessages"] = self.publisher.connectionDiagnostics.events.map(\.message)
            value["errors"] = self.publisher.connectionDiagnostics.events.compactMap { $0.error.map { ["domain": $0.domain, "code": $0.code, "message": $0.message] as [String: Any] } }
            value["pid"] = getpid()
            reply(try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
        }
    }
    nonisolated func cursor(_ x: Double, y: Double, active: Bool, reply: @escaping () -> Void) {
        Task { @MainActor in self.publisher.setComputerUseCursorLocation(CGPoint(x: x, y: y), isActive: active); reply() }
    }
    nonisolated func cursorBurst(reply: @escaping () -> Void) {
        Task { @MainActor in
            self.publisher.setComputerUseCursorLocation(CGPoint(x: 100, y: 200), isActive: true, coalescing: true)
            self.publisher.setComputerUseCursorLocation(.zero, isActive: false)
            self.publisher.setComputerUseCursorLocation(CGPoint(x: 110, y: 200), isActive: true, coalescing: true)
            self.publisher.setComputerUseCursorLocation(CGPoint(x: 120, y: 200), isActive: true, coalescing: true)
            reply()
        }
    }
    nonisolated func markEnding(reply: @escaping () -> Void) {
        Task { @MainActor in self.stream.isInvalidated = true; self.publisher.registerExistingEndingStream(self.stream); reply() }
    }
    nonisolated func startCheckerboard(thread: String, reply: @escaping (String) -> Void) {
        Task { @MainActor in
            let stream = self.publisher.publishCheckerboardStream(threadID: thread, turnID: "owned-turn")
            if thread == "owned-thread" { stream.noteInteraction() }
            reply(stream.presentationID)
        }
    }
    nonisolated func endCheckerboard(_ id: String, reply: @escaping () -> Void) {
        Task { @MainActor in
            (self.publisher.streamsByPresentationID[id] as? RemoteHostedPIPContentStream)?.willEndStream()
            reply()
        }
    }
    nonisolated func retry(reply: @escaping () -> Void) { Task { @MainActor in self.publisher.retryConnection(); reply() } }
    nonisolated func shutdown(reply: @escaping () -> Void) { reply(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) } }
}

private final class BootstrapDelegate: NSObject, NSXPCListenerDelegate {
    let object: Bootstrap
    var connections = [NSXPCConnection]()
    init(_ object: Bootstrap) { self.object = object }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BootstrapProtocol.self)
        connection.exportedObject = object; connections.append(connection); connection.activate(); return true
    }
}

private final class CursorTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [[String: Any]]()
    func record(_ x: Double, _ y: Double, _ active: Bool) {
        lock.lock(); defer { lock.unlock() }; rows.append(["x": x, "y": y, "active": active, "pid": getpid()])
    }
    var values: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
}

private final class Host: NSObject, RemoteHostedPIPContentHostXPCProtocol {
    struct Video {
        let id: String
        let codec: String
        let frame: RemoteHostedPIPVideoFrame
    }

    let trace: CursorTrace
    private let lock = NSLock()
    private var presentationRows = [[String: Any]]()
    private var videoRows = [Video]()
    private var videoToHold: String?
    private var heldVideoReply: RemoteHostedPIPReply?
    var presentations: [[String: Any]] { lock.withLock { presentationRows } }
    var videos: [Video] { lock.withLock { videoRows } }
    func holdNextVideo(for id: String) { lock.withLock { videoToHold = id } }
    func releaseVideo(error: NSError? = nil) {
        let callback = lock.withLock {
            let callback = heldVideoReply
            heldVideoReply = nil
            return callback
        }
        callback?(error)
    }
    private func record(_ row: [String: Any]) { lock.withLock { presentationRows.append(row) } }
    init(_ trace: CursorTrace) { self.trace = trace }
    func setComputerUseCursorLocation(x: Double, y: Double, isActive: Bool, reply: @escaping RemoteHostedPIPReply) {
        trace.record(x, y, isActive)
        reply(x == -999 ? NSError(domain: "OwnedPIPNative", code: 7, userInfo: [NSLocalizedDescriptionKey: "owned cursor failure"]) : nil)
    }
    func publishPresentation(id: String, threadID: String, turnID: String, contextID: UInt32, width: Double, height: Double, reply: @escaping RemoteHostedPIPReply) {
        record(["kind": "publish", "id": id, "thread": threadID, "turn": turnID, "context": contextID, "size": [width, height]])
        reply(threadID == "reject" ? NSError(domain: "OwnedPIPNative", code: 8, userInfo: [NSLocalizedDescriptionKey: "owned publication failure"]) : nil)
    }
    func setSourceProcessIdentifier(_ pid: Int32, presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func publishFrame(presentationID: String, videoData: Data, decoderConfiguration: Data?, codec: String, timestamp: UInt64, isKeyFrame: Bool, reply: @escaping RemoteHostedPIPReply) {
        let held = lock.withLock {
            videoRows.append(Video(id: presentationID, codec: codec,
                frame: .init(videoData: videoData, decoderConfiguration: decoderConfiguration,
                             timestamp: timestamp, isKeyFrame: isKeyFrame)))
            guard videoToHold == presentationID else { return false }
            videoToHold = nil
            heldVideoReply = reply
            return true
        }
        if !held { reply(nil) }
    }
    func prepareOperation(presentationID: String, operationID: UInt64, kind: String, contextID: UInt32, width: Double, height: Double, fencePayload: RemoteHostedPIPFencePayload, reply: @escaping RemoteHostedPIPReply) {
        let fence = xpc_dictionary_copy_mach_send(fencePayload, "fence")
        record(["kind": kind, "id": presentationID, "operation": operationID, "context": contextID,
                "size": [width, height], "hasFence": fence != 0])
        if fence != 0 { mach_port_deallocate(mach_task_self_, fence) }
        reply(nil)
    }
    func completeOperation(presentationID: String, operationID: UInt64, reply: @escaping RemoteHostedPIPReply) {
        record(["kind": "complete", "id": presentationID, "operation": operationID])
        reply(nil)
    }
    func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
        record(["kind": "end", "id": presentationID])
        reply(nil)
    }
    func invalidatePresentation(id: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
        record(["kind": "interaction", "id": presentationID])
        reply(nil)
    }
}

private struct DecodedVideo {
    let width: Int
    let height: Int
    let leftAlpha: UInt8
    let rightAlpha: UInt8
}

private final class VideoDecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DecodedVideo?
    var frame: DecodedVideo? { lock.withLock { value } }

    func store(_ pixels: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels) * (height / 2)
        lock.withLock {
            value = DecodedVideo(width: width, height: height, leftAlpha: base[row + 4 * (width / 4) + 3],
                                 rightAlpha: base[row + 4 * (3 * width / 4) + 3])
        }
    }
}

private func decodeVideo(_ frame: RemoteHostedPIPVideoFrame, width: Int32, height: Int32) throws -> DecodedVideo {
    guard let configuration = frame.decoderConfiguration else { throw RemoteHostedPIPVideoEncoder.Failure.missingSample }
    func requireSuccess(_ status: OSStatus) throws {
        guard status == noErr else { throw RemoteHostedPIPVideoEncoder.Failure.videoToolbox(status) }
    }
    var format: CMVideoFormatDescription?
    let extensions = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["hvcC": configuration],
        kCMFormatDescriptionExtension_ContainsAlphaChannel as String: true
    ] as CFDictionary
    try requireSuccess(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
        width: width, height: height, extensions: extensions, formatDescriptionOut: &format))
    var block: CMBlockBuffer?
    try requireSuccess(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: frame.videoData.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: frame.videoData.count, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block))
    guard let format, let block else { throw RemoteHostedPIPVideoEncoder.Failure.missingSample }
    try requireSuccess(frame.videoData.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
    })
    var timing = CMSampleTimingInfo(duration: .invalid,
        presentationTimeStamp: CMTime(value: Int64(frame.timestamp), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
    var length = frame.videoData.count
    var sample: CMSampleBuffer?
    try requireSuccess(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &length, sampleBufferOut: &sample))
    let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
    var decoder: VTDecompressionSession?
    try requireSuccess(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
        decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &decoder))
    guard let decoder, let sample else { throw RemoteHostedPIPVideoEncoder.Failure.missingSample }
    defer { VTDecompressionSessionInvalidate(decoder) }
    let result = VideoDecodeResult()
    try requireSuccess(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
        status, _, pixels, _, _ in
        if status == noErr, let pixels { result.store(pixels) }
    })
    try requireSuccess(VTDecompressionSessionWaitForAsynchronousFrames(decoder))
    guard let decoded = result.frame else { throw RemoteHostedPIPVideoEncoder.Failure.missingSample }
    return decoded
}

private func roundTripAlpha() async throws -> (decoded: DecodedVideo, interFrame: RemoteHostedPIPVideoFrame) {
    let width = 256
    let height = 160
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                              attributes, &buffer) == kCVReturnSuccess,
          let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw RemoteHostedPIPVideoEncoder.Failure.missingSample
    }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        memset(base + y * stride, 0, stride)
        for x in width / 2..<width {
            let offset = y * stride + 4 * x
            base[offset + 2] = 220
            base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let encoder = try RemoteHostedPIPVideoEncoder(source: buffer, maxPixelDimension: 128)
    func encode() async throws -> RemoteHostedPIPVideoFrame {
        try await withCheckedThrowingContinuation { continuation in
            do { try encoder.encode(buffer) { continuation.resume(with: $0) } }
            catch { continuation.resume(throwing: error) }
        }
    }
    let packet = try await encode()
    try await Task.sleep(for: .milliseconds(17))
    let interFrame = try await encode()
    return (try decodeVideo(packet, width: 128, height: 80), interFrame)
}

private extension Tests {
    static func runOwnedChild() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try! JSONSerialization.data(withJSONObject: ["pid": getpid(), "executable": Bundle.main.executableURL!.path]).write(to: root.appendingPathComponent("child-pid.json"))
        let object = Bootstrap(), delegate = BootstrapDelegate(object), listener = NSXPCListener.service()
        listener.delegate = delegate
        withExtendedLifetime((object, delegate, listener)) { listener.resume(); dispatchMain() }
    }

    static func nativeChecks(_ directory: URL) async {
        let broker = NSXPCConnection(serviceName: Bundle.main.bundleIdentifier! + ".child")
        broker.remoteObjectInterface = NSXPCInterface(with: BootstrapProtocol.self); broker.activate()
        let bootstrap = broker.remoteObjectProxyWithErrorHandler { error in fputs("Bootstrap error: \(error)\n", stderr); exit(1) } as! BootstrapProtocol
        defer { broker.invalidate() }
        let (endpoint, childPID): (NSXPCListenerEndpoint, Int32) = await withCheckedContinuation { continuation in bootstrap.endpoint { continuation.resume(returning: ($0, $1)) } }
        check(childPID > 0 && childPID != getpid(), "actual publisher endpoint is exported from a distinct owned process")
        let trace = CursorTrace(), connection = NSXPCConnection(listenerEndpoint: endpoint)
        let host = Host(trace)
        connection.exportedInterface = RemoteHostedPIPXPC.hostInterface(); connection.exportedObject = host
        connection.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface(); connection.activate(); defer { connection.invalidate() }
        let producer = connection.remoteObjectProxyWithErrorHandler { error in fputs("Producer error: \(error)\n", stderr); exit(1) } as! RemoteHostedPIPContentProducerXPCProtocol
        func call(_ body: (@escaping RemoteHostedPIPReply) -> Void) async -> NSError? {
            await withCheckedContinuation { continuation in body { continuation.resume(returning: $0) } }
        }
        func snapshot() async -> [String: Any] {
            let data: Data = await withCheckedContinuation { continuation in bootstrap.snapshot { continuation.resume(returning: $0) } }
            return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func waitState(_ label: String, _ condition: ([String: Any]) -> Bool) async -> [String: Any] {
            for _ in 0..<200 {
                let value = await snapshot()
                if condition(value) { check(true, label); return value }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            check(false, label); return [:]
        }
        let connectError = await call { producer.connect(reply: $0) }
        check(connectError == nil, "actual publisher acknowledges native connect")
        let connected = await waitState("actual connection owner queues publication through the required stream backend") { $0["published"] as? Bool == true }
        check(connection.processIdentifier == childPID && connected["pid"] as? Int32 == childPID, "native producer messages and state use the actual peer PID")
        let displayError = await call { producer.setMaxDisplaySize(200.5, reply: $0) }
        check(displayError == nil, "native display command replies successfully")
        _ = await waitState("native display command rounds and queues stream size update") { $0["streamDisplayBits"] as? String == String(201.0.bitPattern) }
        let videoError = await call { producer.setVideoMaxPixelDimension(2.01, presentationID: "owned", reply: $0) }
        let videoState = await snapshot()
        check(videoError == nil && videoState["videoDimension"] as? Int == 3, "native video command applies ceil and the pixel limit")
        let invalidError = await call { producer.setVideoMaxPixelDimension(.nan, presentationID: "owned", reply: $0) }
        check(invalidError?.code == 1 && invalidError!.domain.hasPrefix("ComputerUse.RemoteHostedPIPContentPublisher."), "actual publisher serializes its unavailable-presentation NSError")
        let actionError = await call { producer.performAction(presentationID: "owned", kind: "owned-custom", reply: $0) }
        let actionState = await snapshot()
        check(actionError == nil && actionState["actions"] as? [String] == ["owned-custom"], "native action command dispatches to the registered stream")
        let missingError = await call { producer.performAction(presentationID: "配置-missing", kind: "owned-custom", reply: $0) }
        check(missingError?.code == 1, "native action rejects an unknown Unicode presentation")
        let petError = await call { producer.setPetLocation(x: -7.25, y: 19.5, available: true, reply: $0) }
        let pet = await snapshot()
        check(petError == nil && pet["petXBits"] as? String == String((-7.25).bitPattern) && pet["petPresent"] as? Bool == true,
            "native pet command updates the shared location through the actual publisher")
        await withCheckedContinuation { continuation in bootstrap.cursor(-4, y: 2.5, active: false) { continuation.resume() } }
        guard await waitUntil({ trace.values.count == 1 }) else { fatalError("Cursor message missing") }
        check(trace.values[0]["x"] as? Double == -4 && trace.values[0]["y"] as? Double == 2.5 && trace.values[0]["active"] as? Bool == false,
            "queued cursor notification crosses the actual publisher's native host connection")
        await withCheckedContinuation { continuation in bootstrap.cursor(-999, y: 8, active: true) { continuation.resume() } }
        let failure = await waitState("host cursor error is recorded in observable diagnostics") { ($0["diagnosticMessages"] as? [String])?.contains("Cursor location notification failed") == true }
        let errors = failure["errors"] as! [[String: Any]]
        check(errors.first?["domain"] as? String == "OwnedPIPNative" && errors.first?["code"] as? Int == 7 && errors.first?["message"] as? String == "owned cursor failure",
            "cursor diagnostics preserve native NSError domain, code and localized message")
        let beforeBurst = trace.values.count
        await withCheckedContinuation { continuation in bootstrap.cursorBurst { continuation.resume() } }
        let sawBurst = await waitUntil { trace.values.count >= beforeBurst + 2 }
        let burst = Array(trace.values.dropFirst(beforeBurst))
        check(sawBurst && burst.count == 2 && burst.first?["active"] as? Bool == false &&
              burst.last?["active"] as? Bool == true && burst.last?["x"] as? Double == 120,
              "cursor coalesces motion without losing hide-before-show ordering")
        await withCheckedContinuation { continuation in bootstrap.markEnding { continuation.resume() } }
        let focusError = await call { producer.performAction(presentationID: "owned", kind: "focus-presentation", reply: $0) }
        let focusState = await snapshot()
        check(focusError == nil && focusState["actions"] as? [String] == ["owned-custom", "focus"], "ending published stream accepts its focus action")
        let endedError = await call { producer.didEndStream(presentationID: "owned", reply: $0) }
        let ended = await snapshot()
        check(endedError == nil && ended["endingCount"] as? Int == 0 && ended["cancellations"] as? Int == 1,
            "native ending acknowledgement removes the identical stream and cancels its timeout")
        let duplicateError = await call { producer.didEndStream(presentationID: "owned", reply: $0) }
        let duplicateState = await snapshot()
        check(duplicateError == nil && duplicateState["cancellations"] as? Int == 1, "duplicate native ending acknowledgement is a no-op")

        func startCheckerboard(_ thread: String) async -> String {
            await withCheckedContinuation { continuation in bootstrap.startCheckerboard(thread: thread) { continuation.resume(returning: $0) } }
        }
        func endCheckerboard(_ id: String) async {
            await withCheckedContinuation { continuation in bootstrap.endCheckerboard(id) { continuation.resume() } }
        }
        func events(_ id: String) -> [[String: Any]] { host.presentations.filter { $0["id"] as? String == id } }
        let board = await startCheckerboard("owned-thread")
        _ = await waitState("native checkerboard becomes published after the host reply") {
            ($0["publishedNativeIDs"] as? [String])?.contains(board) == true
        }
        let presentation = events(board).first
        let context = presentation?["context"] as? UInt32
        check(context != nil && context != 0 && presentation?["size"] as? [Double] == [201, 201] &&
              presentation?["thread"] as? String == "owned-thread" && presentation?["turn"] as? String == "owned-turn",
              "native checkerboard sends the graphics context, size, thread and turn to the separate host")
        let interaction = await waitUntil { events(board).last?["kind"] as? String == "interaction" }
        check(interaction && events(board).first?["kind"] as? String == "publish",
              "queued interaction follows publication and uses the same presentation ID")
        for (index, side) in [251.0, 279.0].enumerated() {
            let error = await call { producer.setMaxDisplaySize(side, reply: $0) }
            let operation = UInt64(index + 1)
            let delivered = await waitUntil { events(board).count == index * 2 + 4 }
            let pair = Array(events(board).suffix(2))
            check(error == nil && delivered && pair.count == 2 && pair[0]["kind"] as? String == "resize" &&
                  pair[0]["operation"] as? UInt64 == operation && pair[0]["context"] as? UInt32 == context &&
                  pair[0]["size"] as? [Double] == [side, side] && pair[0]["hasFence"] as? Bool == true &&
                  pair[1]["kind"] as? String == "complete" && pair[1]["operation"] as? UInt64 == operation,
                  "native checkerboard resize \(operation) transfers a fence then completes the matching operation")
        }
        await endCheckerboard(board)
        let sawEnd = await waitUntil { events(board).last?["kind"] as? String == "end" }
        check(sawEnd, "native checkerboard notifies the host before waiting for its ending acknowledgement")
        let boardEndError = await call { producer.didEndStream(presentationID: board, reply: $0) }
        let boardEnded = await snapshot()
        check(boardEndError == nil && (boardEnded["endingNativeIDs"] as? [String])?.contains(board) == false,
              "native checkerboard acknowledgement removes the ending presentation")

        let timeoutBoard = await startCheckerboard("owned-timeout")
        _ = await waitState("second checkerboard publishes independently") { ($0["publishedNativeIDs"] as? [String])?.contains(timeoutBoard) == true }
        await endCheckerboard(timeoutBoard)
        _ = await waitState("unacknowledged checkerboard is removed after the native timeout") {
            events(timeoutBoard).last?["kind"] as? String == "end" && ($0["endingNativeIDs"] as? [String])?.contains(timeoutBoard) == false
        }

        let rejectedBoard = await startCheckerboard("reject")
        let rejectedState = await waitState("host rejection is recorded without publishing the checkerboard") {
            events(rejectedBoard).first?["kind"] as? String == "publish" &&
            ($0["diagnosticMessages"] as? [String])?.contains("Presentation publication failed") == true
        }
        check((rejectedState["publishedNativeIDs"] as? [String])?.contains(rejectedBoard) == false,
              "host-rejected presentation remains unpublished")
        await endCheckerboard(rejectedBoard)
        _ = await waitState("unpublished checkerboard ends locally without notifying the host") {
            events(rejectedBoard).count == 1 && ($0["endingNativeIDs"] as? [String])?.contains(rejectedBoard) == false
        }

        let videoBoard = await startCheckerboard("owned-video")
        _ = await waitState("video fixture publishes its source presentation") {
            ($0["publishedNativeIDs"] as? [String])?.contains(videoBoard) == true
        }
        func videoFrames() -> [Host.Video] { host.videos.filter { $0.id == videoBoard } }
        func videoAction(_ kind: String) async -> NSError? {
            await call { producer.performAction(presentationID: videoBoard, kind: kind, reply: $0) }
        }
        host.holdNextVideo(for: videoBoard)
        let videoLimit = await call { producer.setVideoMaxPixelDimension(127.2, presentationID: videoBoard, reply: $0) }
        let startVideo = await videoAction("dom-video-start")
        let firstVideoArrived = await waitUntil { videoFrames().count == 1 }
        check(videoLimit == nil && startVideo == nil && firstVideoArrived, "video start sends the cached frame over XPC")
        guard let firstVideo = videoFrames().first else { return }
        check(firstVideo.codec == "hvc1.1.6.L93.B0" && firstVideo.frame.isKeyFrame &&
              firstVideo.frame.decoderConfiguration?.isEmpty == false && firstVideo.frame.timestamp > 0,
              "XPC sends the HEVC codec, keyframe configuration and uptime timestamp")
        let firstDecoded = try? decodeVideo(firstVideo.frame, width: 128, height: 128)
        check(firstDecoded?.width == 128 && firstDecoded?.height == 128 &&
              (firstDecoded?.leftAlpha ?? 0) > 230, "host decodes the XPC packet at the requested even size")
        let blockedResize = await call { producer.setMaxDisplaySize(288, reply: $0) }
        let blockedFrame = await waitUntil { events(videoBoard).last?["kind"] as? String == "complete" }
        check(blockedResize == nil && blockedFrame && videoFrames().count == 1, "host acknowledgement gates video while layer resize continues")
        host.releaseVideo()
        try? await Task.sleep(for: .milliseconds(100))
        let nextResize = await call { producer.setMaxDisplaySize(292, reply: $0) }
        let secondVideoArrived = await waitUntil { videoFrames().count == 2 }
        check(nextResize == nil && secondVideoArrived &&
              videoFrames().last!.frame.timestamp > firstVideo.frame.timestamp,
              "encoding resumes after acknowledgement with a newer timestamp")
        let stopVideo = await videoAction("dom-video-stop")
        let stoppedResize = await call { producer.setMaxDisplaySize(298, reply: $0) }
        let stoppedFrame = await waitUntil {
            events(videoBoard).filter { $0["kind"] as? String == "complete" }.count == 3
        }
        check(stopVideo == nil && stoppedResize == nil && stoppedFrame && videoFrames().count == 2,
              "video stop leaves the layer stream running and sends no encoded frames")
        host.holdNextVideo(for: videoBoard)
        let retryVideo = await videoAction("dom-video-start")
        let retryArrived = await waitUntil { videoFrames().count == 3 }
        check(retryVideo == nil && retryArrived && videoFrames().last?.frame.isKeyFrame == true,
              "starting video again sends a fresh keyframe from the latest cached image")
        host.releaseVideo(error: NSError(domain: "OwnedPIPNative", code: 9))
        _ = await waitState("host rejection is recorded and stops video delivery") {
            ($0["diagnosticMessages"] as? [String])?.contains("Video frame delivery failed") == true
        }
        let rejectedVideoResize = await call { producer.setMaxDisplaySize(301, reply: $0) }
        let rejectedVideoFrame = await waitUntil {
            events(videoBoard).filter { $0["kind"] as? String == "complete" }.count == 4
        }
        check(rejectedVideoResize == nil && rejectedVideoFrame && videoFrames().count == 3,
              "rejected video does not keep sending frames")
        await endCheckerboard(videoBoard)
        do {
            let (decodedAlpha, interFrame) = try await roundTripAlpha()
            check(decodedAlpha.width == 128 && decodedAlpha.height == 80 &&
                  decodedAlpha.leftAlpha < 12 && decodedAlpha.rightAlpha > 230,
                  "HEVC round trip preserves transparency (\(decodedAlpha.width)×\(decodedAlpha.height), alpha \(decodedAlpha.leftAlpha)/\(decodedAlpha.rightAlpha))")
            check(!interFrame.isKeyFrame && interFrame.decoderConfiguration == nil,
                  "inter-frame packet omits the HEVC decoder configuration")
        } catch {
            check(false, "HEVC alpha round trip: \(error)")
        }

        let replayBoard = await startCheckerboard("owned-replay")
        _ = await waitState("active checkerboard publishes before disconnect") { ($0["publishedNativeIDs"] as? [String])?.contains(replayBoard) == true }
        await withCheckedContinuation { continuation in bootstrap.retry { continuation.resume() } }
        let retried = await waitState("native retry invalidates the current host and clears shared pet state") { $0["status"] as? String == "waitingForHost" && $0["petPresent"] as? Bool == false }
        check((retried["publishedNativeIDs"] as? [String])?.contains(replayBoard) == false,
              "disconnect clears the active checkerboard's host publication")
        let replacement = NSXPCConnection(listenerEndpoint: endpoint)
        replacement.exportedInterface = RemoteHostedPIPXPC.hostInterface()
        replacement.exportedObject = host
        replacement.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface()
        replacement.activate()
        defer { replacement.invalidate() }
        let newProducer = replacement.remoteObjectProxyWithErrorHandler { error in fputs("Replacement producer error: \(error)\n", stderr); exit(1) }
            as! RemoteHostedPIPContentProducerXPCProtocol
        let replacementError = await call { newProducer.connect(reply: $0) }
        let replayed = await waitState("reconnecting republishes the same active presentation") {
            events(replayBoard).count == 2 && ($0["publishedNativeIDs"] as? [String])?.contains(replayBoard) == true
        }
        check(replacementError == nil && events(replayBoard).allSatisfy { $0["kind"] as? String == "publish" },
              "host replacement rebuilds the checkerboard without a stale resize or ending operation")
        let states: [[String: Any]] = [connected, pet, failure, ended, retried, replayed]
        try! JSONSerialization.data(withJSONObject: states, options: .sortedKeys).write(to: directory.appendingPathComponent("native-producer-states.json"))
        try! JSONSerialization.data(withJSONObject: trace.values, options: .sortedKeys).write(to: directory.appendingPathComponent("host-cursor-trace.json"))
        try! JSONSerialization.data(withJSONObject: host.presentations, options: .sortedKeys).write(to: directory.appendingPathComponent("host-presentation-trace.json"))
        try! JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks, "hostPID": getpid(), "producerPID": childPID,
            "commandCases": 54, "concreteRendererUsed": true], options: .sortedKeys).write(to: directory.appendingPathComponent("result.json"))
        await withCheckedContinuation { continuation in bootstrap.shutdown { continuation.resume() } }
    }
}
