import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

@MainActor
final class RemoteHostedPIPWindowRenderer: RemoteHostedPIPStreamRenderer {
    private enum CaptureError: Error {
        case sourceWindowUnavailable(CGWindowID)
        case invalidCaptureSize
        case captureStopped
    }

    // ScreenCaptureKit owns each sample until delivery. Keep at most the latest
    // frame queued for the main actor so a busy UI cannot hold the capture pool.
    private struct Frame: @unchecked Sendable {
        let sample: CMSampleBuffer
    }

    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
        let frames: AsyncStream<Frame>
        let continuation: AsyncStream<Frame>.Continuation

        override init() {
            (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sample.isValid, CMSampleBufferDataIsReady(sample) else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let status = attachments.first?[.status] as? Int,
                status != SCFrameStatus.complete.rawValue, status != SCFrameStatus.started.rawValue { return }
            continuation.yield(Frame(sample: sample))
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            continuation.finish()
        }
    }

    private let windowID: CGWindowID
    private var associatedWindowIDs: Set<CGWindowID>
    private let onFrame: (CVPixelBuffer) -> Void
    private let onCursorFrame: (CVPixelBuffer) -> Void
    private let layer = AVSampleBufferDisplayLayer()
    private let cursorLayer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    private var output: Output?
    private var frameDelivery: Task<Void, Never>?
    private var firstFrame: CheckedContinuation<Void, Never>?
    private var firstFrameTimeout: Task<Void, Never>?
    private var sourceSize = CGSize.zero
    private var sourceFrame: CGRect?
    private var captureGeometry: CaptureGeometry?
    private var geometryObserver: RemoteHostedPIPWindowGeometryObserver?
    private var windowFocus: RemoteHostedPIPWindowFocus?
    private var onGeometryChange: (() -> Void)?
    private var frameSize: CGSize?
    private var stopped = false
    private var cursorWindowID: CGWindowID?
    private var cursorCrop: CGRect?
    private var cursorGeneration = UUID()
    private var cursorTask: Task<Void, Never>?
    private(set) var sourceProcessIdentifier: Int32?

    init(windowID: CGWindowID, associatedWindowIDs: Set<CGWindowID>,
         onCursorFrame: @escaping (CVPixelBuffer) -> Void = { _ in }, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.windowID = windowID
        self.associatedWindowIDs = associatedWindowIDs
        self.onFrame = onFrame
        self.onCursorFrame = onCursorFrame
        layer.videoGravity = .resizeAspect
        cursorLayer.videoGravity = .resize
        cursorLayer.isHidden = true
    }

    func prepare(producer: RemoteHostedPIPContentProducer, isActive: Bool, maxDisplaySize: CGFloat) async throws -> CGSize {
        let (plan, geometry) = try await capturePlan(associatedWindowIDs: associatedWindowIDs)
        sourceProcessIdentifier = plan.pid
        windowFocus = RemoteHostedPIPWindowFocus(windowID: windowID, expectedPID: plan.pid)
        try await startCapture(plan, geometry: geometry)
        let size = presentationSize(forMaxDisplaySize: maxDisplaySize)
        try await resize(producer: producer, isActive: isActive, size: size)
        if let onGeometryChange {
            geometryObserver = RemoteHostedPIPWindowGeometryObserver(windowID: windowID, associatedWindowIDs: associatedWindowIDs,
                                                                    pid: sourceProcessIdentifier, onChange: onGeometryChange)
        }
        return size
    }

    private struct CaptureGeometry: Equatable {
        let frame: CGRect
        let region: CGRect?
        let displayID: CGDirectDisplayID?
        let windowIDs: Set<CGWindowID>
        let displayFrames: [CGDirectDisplayID: CGRect]
        let width: Int
        let height: Int

        func usesSameCapture(as other: Self) -> Bool {
            region == other.region && displayID == other.displayID && windowIDs == other.windowIDs
                && width == other.width && height == other.height
        }
    }

    private typealias CapturePlan = (filter: SCContentFilter, configuration: SCStreamConfiguration, frame: CGRect, pid: Int32?)

    private func startCapture(_ plan: CapturePlan, geometry: CaptureGeometry) async throws {
        guard !stopped else { throw CaptureError.captureStopped }
        sourceSize = plan.frame.size
        frameSize = nil
        let output = Output()
        let capture = SCStream(filter: plan.filter, configuration: plan.configuration, delegate: output)
        try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cua.pip.window"))
        self.output = output
        stream = capture
        frameDelivery = Task { [weak self] in
            for await frame in output.frames {
                guard let self, self.output === output else { return }
                self.deliver(frame.sample)
            }
            guard let self, self.output === output else { return }
            self.stream = nil
            self.sourceFrame = nil
            self.captureGeometry = nil
            self.restartCursorCapture()
            self.finishFirstFrameWait()
            self.layer.sampleBufferRenderer.flush()
            self.geometryObserver?.captureInterrupted()
        }

        do { try await capture.startCapture() }
        catch {
            if stream === capture { await closeCapture() }
            throw error
        }
        if frameSize == nil, stream != nil {
            await withCheckedContinuation { continuation in
                firstFrame = continuation
                firstFrameTimeout = Task { [weak self] in
                    guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
                    self?.finishFirstFrameWait()
                }
            }
        }
        guard stream === capture else { throw CaptureError.captureStopped }
        sourceFrame = plan.frame
        captureGeometry = geometry
        restartCursorCapture()
    }

    func setAssociatedWindowIDs(_ ids: Set<CGWindowID>) async throws {
        guard ids != associatedWindowIDs else { return }
        guard sourceSize != .zero else { associatedWindowIDs = ids; return }
        try await refreshGeometry(associatedWindowIDs: ids)
        associatedWindowIDs = ids
        geometryObserver?.updateWindows(windowID: windowID, associatedWindowIDs: ids)
    }

    func setGeometryChangeHandler(_ handler: @escaping () -> Void) {
        onGeometryChange = handler
    }

    func focusPresentation() {
        windowFocus?.toggle()
    }

    func refreshGeometry() async throws {
        try await refreshGeometry(associatedWindowIDs: associatedWindowIDs)
    }

    private func refreshGeometry(associatedWindowIDs: Set<CGWindowID>) async throws {
        let (plan, geometry): (CapturePlan, CaptureGeometry)
        do { (plan, geometry) = try await capturePlan(associatedWindowIDs: associatedWindowIDs) }
        catch let error as CaptureError {
            if case .sourceWindowUnavailable = error { await closeCapture() }
            throw error
        }
        guard !stopped else { throw CaptureError.captureStopped }
        guard plan.pid == sourceProcessIdentifier else {
            await closeCapture()
            throw CaptureError.captureStopped
        }
        if let previous = captureGeometry, stream != nil, previous.usesSameCapture(as: geometry) {
            guard previous != geometry else { return }
            sourceFrame = geometry.frame
            captureGeometry = geometry
            restartCursorCapture()
        } else {
            await closeCapture()
            try await startCapture(plan, geometry: geometry)
        }
    }

    private func capturePlan(associatedWindowIDs: Set<CGWindowID>) async throws -> (CapturePlan, CaptureGeometry) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.sourceWindowUnavailable(windowID)
        }
        let (filter, region, frame, displayID, includedIDs) = captureFilter(for: window, in: content, associatedWindowIDs: associatedWindowIDs)
        let configuration = try Self.captureConfiguration(filter: filter, frame: frame, region: region)
        let geometry = CaptureGeometry(frame: frame, region: region, displayID: displayID, windowIDs: includedIDs,
            displayFrames: Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0.frame) }),
            width: configuration.width, height: configuration.height)
        return ((filter, configuration, frame, window.owningApplication?.processID), geometry)
    }

    private static func captureConfiguration(filter: SCContentFilter, frame: CGRect, region: CGRect?) throws -> SCStreamConfiguration {
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let width = ceil(frame.width * scale)
        let height = ceil(frame.height * scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(Int32.max), height <= CGFloat(Int32.max) else { throw CaptureError.invalidCaptureSize }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        configuration.shouldBeOpaque = false
        configuration.queueDepth = 5
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        if let region { configuration.sourceRect = region }

        return configuration
    }

    func presentationSize(forMaxDisplaySize size: CGFloat) -> CGSize {
        let maximum = RemoteHostedPIPContentPublisher.normalizedMaxDisplaySize(size)
        let reference = frameSize ?? sourceSize
        let ratio = maximum / max(reference.width, reference.height)
        return CGSize(width: max(1, reference.width * ratio), height: max(1, reference.height * ratio))
    }

    func resize(producer: RemoteHostedPIPContentProducer, isActive: Bool, size: CGSize) async throws {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let root = producer.rootLayer
        root.frame = CGRect(origin: .zero, size: size)
        root.masksToBounds = true
        layer.frame = root.bounds
        if layer.superlayer !== root { root.addSublayer(layer) }
        if cursorLayer.superlayer !== root { root.addSublayer(cursorLayer) }
        layoutCursor()
        CATransaction.commit()
        CATransaction.flush()
    }

    func stop() async {
        stopped = true
        windowFocus = nil
        geometryObserver?.stop()
        geometryObserver = nil
        let oldCursorTask = cursorTask
        layer.removeFromSuperlayer()
        cursorLayer.removeFromSuperlayer()
        await closeCapture()
        await oldCursorTask?.value
    }

    private func closeCapture() async {
        let capture = stream
        stream = nil
        sourceFrame = nil
        captureGeometry = nil
        restartCursorCapture()
        output?.continuation.finish()
        output = nil
        frameDelivery?.cancel()
        frameDelivery = nil
        finishFirstFrameWait()
        layer.sampleBufferRenderer.flush()
        if let capture { try? await capture.stopCapture() }
    }

    private func finishFirstFrameWait() {
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        firstFrame?.resume()
        firstFrame = nil
    }

    private func deliver(_ sample: CMSampleBuffer) {
        if let buffer = sample.imageBuffer {
            frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            onFrame(buffer)
        } else if let format = sample.formatDescription, format.mediaType == .video {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            if dimensions.width > 0, dimensions.height > 0 {
                frameSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            }
        }
        layer.sampleBufferRenderer.enqueue(sample)
        if frameSize != nil { finishFirstFrameWait() }
    }

    func setCursorWindowID(_ id: CGWindowID?) {
        guard id != cursorWindowID else { return }
        cursorWindowID = id
        restartCursorCapture()
    }

    private func restartCursorCapture() {
        let generation = UUID()
        cursorGeneration = generation
        cursorTask?.cancel()
        cursorTask = nil
        cursorCrop = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCursor()
        CATransaction.commit()
        cursorLayer.sampleBufferRenderer.flush()
        guard !stopped, let sourceFrame, let cursorWindowID else { return }
        cursorTask = Task { [weak self] in
            guard let plan = try? await Self.cursorCapturePlan(windowID: cursorWindowID, source: sourceFrame),
                  self?.cursorGeneration == generation, !Task.isCancelled else { return }
            let output = Output()
            let capture = SCStream(filter: plan.filter, configuration: plan.configuration, delegate: output)
            do {
                try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cua.pip.cursor"))
                try await capture.startCapture()
                for await frame in output.frames {
                    guard let self, self.cursorGeneration == generation, !Task.isCancelled else { break }
                    self.deliverCursor(frame.sample, crop: plan.frame)
                }
            } catch {}
            output.continuation.finish()
            try? await capture.stopCapture()
            guard let self, self.cursorGeneration == generation else { return }
            self.cursorCrop = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layoutCursor()
            CATransaction.commit()
        }
    }

    private static func cursorCapturePlan(windowID: CGWindowID, source: CGRect) async throws -> CapturePlan? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let cursor = content.windows.first(where: {
            $0.windowID == windowID && $0.isOnScreen && $0.owningApplication?.processID == getpid()
        }) else { return nil }
        let displays = content.displays.filter { !$0.frame.intersection(source).isEmpty }
        guard let display = displays.max(by: {
            let left = $0.frame.intersection(cursor.frame)
            let right = $1.frame.intersection(cursor.frame)
            let leftArea = left.isNull ? 0 : left.width * left.height
            let rightArea = right.isNull ? 0 : right.width * right.height
            if leftArea != rightArea { return leftArea < rightArea }
            let leftSource = $0.frame.intersection(source)
            let rightSource = $1.frame.intersection(source)
            return leftSource.width * leftSource.height < rightSource.width * rightSource.height
        }) else { return nil }
        let crop = display.frame.intersection(source)
        let region = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let filter = SCContentFilter(display: display, including: [cursor])
        let configuration = try captureConfiguration(filter: filter, frame: crop, region: region)
        return (filter, configuration, crop, cursor.owningApplication?.processID)
    }

    private func deliverCursor(_ sample: CMSampleBuffer, crop: CGRect) {
        guard let pixels = sample.imageBuffer else { return }
        cursorLayer.sampleBufferRenderer.enqueue(sample)
        if cursorCrop != crop {
            cursorCrop = crop
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutCursor()
            CATransaction.commit()
        }
        onCursorFrame(pixels)
    }

    private func layoutCursor() {
        guard let sourceFrame, let cursorCrop else { cursorLayer.isHidden = true; return }
        let size = layer.bounds.size
        let xScale = size.width / sourceFrame.width
        let yScale = size.height / sourceFrame.height
        cursorLayer.frame = CGRect(x: (cursorCrop.minX - sourceFrame.minX) * xScale,
                                   y: (sourceFrame.maxY - cursorCrop.maxY) * yScale,
                                   width: cursorCrop.width * xScale, height: cursorCrop.height * yScale)
        cursorLayer.isHidden = false
    }

    private func captureFilter(for window: SCWindow, in content: SCShareableContent,
                               associatedWindowIDs: Set<CGWindowID>)
        -> (SCContentFilter, CGRect?, CGRect, CGDirectDisplayID?, Set<CGWindowID>) {
        let pid = window.owningApplication?.processID
        let associated = content.windows.filter { candidate in
            candidate.windowID != windowID && associatedWindowIDs.contains(candidate.windowID) && candidate.isOnScreen
                && (pid == nil || candidate.owningApplication?.processID == pid)
        }
        if !associated.isEmpty,
           let display = content.displays.max(by: {
               intersectionArea($0.frame, window.frame) < intersectionArea($1.frame, window.frame)
           }), intersectionArea(display.frame, window.frame) > 0 {
            let union = associated.reduce(window.frame) { $0.union($1.frame) }
            let frame = union.intersection(display.frame)
            let crop = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let included = [window] + associated
            return (SCContentFilter(display: display, including: included), crop, frame, display.displayID, Set(included.map(\.windowID)))
        }
        return (SCContentFilter(desktopIndependentWindow: window), nil, window.frame, nil, [window.windowID])
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}

extension RemoteHostedPIPContentPublisher {
    func publishWindowStream(threadID: String, turnID: String, windowID: CGWindowID,
                             associatedWindowIDs: Set<CGWindowID> = [],
                             onFrame: @escaping (CVPixelBuffer) -> Void = { _ in }) -> RemoteHostedPIPContentStream {
        let stream = RemoteHostedPIPContentStream(publisher: self, threadID: threadID, turnID: turnID) { publishFrame in
            RemoteHostedPIPWindowRenderer(windowID: windowID, associatedWindowIDs: []) { frame in
                publishFrame(frame)
                onFrame(frame)
            }
        }
        stream.setAssociatedWindowIDs(associatedWindowIDs)
        registerExistingStream(stream)
        return stream
    }
}
