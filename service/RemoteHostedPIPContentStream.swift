import CoreGraphics
import CoreVideo
import Foundation

@MainActor
protocol RemoteHostedPIPStreamRenderer: AnyObject {
    var sourceProcessIdentifier: Int32? { get }
    func presentationSize(forMaxDisplaySize size: CGFloat) -> CGSize
    func setAssociatedWindowIDs(_ ids: Set<CGWindowID>) async throws
    func setCursorWindowID(_ id: CGWindowID?)
    func setGeometryChangeHandler(_ handler: @escaping () -> Void)
    func refreshGeometry() async throws
    func focusPresentation()
    func prepare(producer: RemoteHostedPIPContentProducer, isActive: Bool, maxDisplaySize: CGFloat) async throws -> CGSize
    func resize(producer: RemoteHostedPIPContentProducer, isActive: Bool, size: CGSize) async throws
    func stop() async
}

extension RemoteHostedPIPStreamRenderer {
    var sourceProcessIdentifier: Int32? { nil }
    func setAssociatedWindowIDs(_ ids: Set<CGWindowID>) async throws {}
    func setCursorWindowID(_ id: CGWindowID?) {}
    func setGeometryChangeHandler(_ handler: @escaping () -> Void) {}
    func refreshGeometry() async throws {}
    func focusPresentation() {}

    func presentationSize(forMaxDisplaySize size: CGFloat) -> CGSize {
        let side = RemoteHostedPIPContentPublisher.normalizedMaxDisplaySize(size)
        return CGSize(width: side, height: side)
    }
}

extension RemoteHostedPIPCheckerboardRenderer: RemoteHostedPIPStreamRenderer {}

@MainActor
final class RemoteHostedPIPContentStream: RemoteHostedPIPPublishingStream {
    private enum Error: Int, Swift.Error, CustomNSError {
        case couldNotCreateFence = 0
        case missingPublisher = 2

        static var errorDomain: String { "ComputerUse.RemoteHostedPIPContentStream.Error" }
        var errorCode: Int { rawValue }
        var errorUserInfo: [String: Any] { [:] }
    }

    private struct Publication {
        let producer: RemoteHostedPIPContentProducer
        let renderer: any RemoteHostedPIPStreamRenderer
        var size: CGSize
        var nextOperation: UInt64 = 1
    }

    let presentationID = UUID().uuidString
    let threadID: String
    let turnID: String
    private weak var publisher: RemoteHostedPIPContentPublisher?
    private let makeRenderer: (@escaping (CVPixelBuffer) -> Void) -> any RemoteHostedPIPStreamRenderer
    private var publication: Publication?
    private var associatedWindowIDs = Set<CGWindowID>()
    private var associatedWindowsNeedUpdate = false
    private var geometryRefreshQueued = false
    private var cursorWindowID: CGWindowID?
    private var frameSourceID: UUID?
    private var latestVideoFrame: CVPixelBuffer?
    private var videoEnabled = false
    private var inFlightVideoID: UUID?
    private var videoEncoder: RemoteHostedPIPVideoEncoder?
    private(set) var isPublished = false
    private(set) var isInvalidated = false
    var maxDisplaySize: CGFloat
    var maxVideoPixelDimension = 720

    init(publisher: RemoteHostedPIPContentPublisher, threadID: String, turnID: String,
         makeRenderer: @escaping (@escaping (CVPixelBuffer) -> Void) -> any RemoteHostedPIPStreamRenderer) {
        self.publisher = publisher
        self.threadID = threadID
        self.turnID = turnID
        self.makeRenderer = makeRenderer
        maxDisplaySize = publisher.maxDisplaySize
    }

    func publish(to connection: NSXPCConnection) async throws {
        guard let publisher else { throw Error.missingPublisher }
        guard !isInvalidated, publication == nil, publisher.transport.connection === connection else { return }
        let producer = try RemoteHostedPIPContentProducer()
        let sourceID = UUID()
        frameSourceID = sourceID
        let renderer = makeRenderer { [weak self] pixels in
            guard let self, self.frameSourceID == sourceID, !self.isInvalidated else { return }
            self.latestVideoFrame = pixels
            self.sendVideoFrameIfReady()
        }
        renderer.setGeometryChangeHandler { [weak self] in
            guard let self, self.frameSourceID == sourceID else { return }
            self.requestGeometryUpdate()
        }
        let initialWindowIDs = associatedWindowIDs
        let size: CGSize
        do {
            try await renderer.setAssociatedWindowIDs(initialWindowIDs)
            size = try await renderer.prepare(producer: producer, isActive: true, maxDisplaySize: maxDisplaySize)
        } catch {
            producer.invalidate()
            await renderer.stop()
            throw error
        }
        guard !isInvalidated, frameSourceID == sourceID, publisher.transport.connection === connection else {
            producer.invalidate()
            await renderer.stop()
            return
        }
        publication = Publication(producer: producer, renderer: renderer, size: size)
        if initialWindowIDs == associatedWindowIDs { associatedWindowsNeedUpdate = false }
        renderer.setCursorWindowID(cursorWindowID)
        do {
            try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
                host.publishPresentation(id: presentationID, threadID: threadID, turnID: turnID,
                                         contextID: producer.contextID, width: size.width, height: size.height, reply: reply)
            }
        } catch {
            if publication?.producer === producer { resetHostState() }
            throw error
        }
        guard publication?.producer === producer, publisher.transport.connection === connection else { return }
        isPublished = true
        sendVideoFrameIfReady()
        if let pid = renderer.sourceProcessIdentifier {
            try? await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
                host.setSourceProcessIdentifier(pid, presentationID: presentationID, reply: reply)
            }
        }
    }

    func setAssociatedWindowIDs(_ ids: Set<CGWindowID>) {
        guard ids != associatedWindowIDs || associatedWindowsNeedUpdate else { return }
        associatedWindowIDs = ids
        associatedWindowsNeedUpdate = true
        requestGeometryUpdate()
    }

    private func requestGeometryUpdate() {
        guard !geometryRefreshQueued, !isInvalidated, let publisher else { return }
        geometryRefreshQueued = true
        publisher.updateWindowGeometry(self)
    }

    func applyWindowGeometry() async throws {
        geometryRefreshQueued = false
        guard let publication else { return }
        guard associatedWindowsNeedUpdate else {
            try await publication.renderer.refreshGeometry()
            return
        }
        let ids = associatedWindowIDs
        try await publication.renderer.setAssociatedWindowIDs(ids)
        if self.publication?.producer === publication.producer, associatedWindowIDs == ids {
            associatedWindowsNeedUpdate = false
        }
    }

    func noteInteraction() {
        guard !isInvalidated else { return }
        publisher?.noteInteraction(self)
    }

    func setCursorWindowID(_ id: CGWindowID?) {
        guard !isInvalidated, id != cursorWindowID else { return }
        cursorWindowID = id
        publication?.renderer.setCursorWindowID(id)
    }

    func updateMaxDisplaySize(_ size: CGFloat, connection: NSXPCConnection?) async throws {
        maxDisplaySize = size
        guard isPublished, !isInvalidated, let publication, let connection,
              publisher?.transport.connection === connection else { return }
        let dimensions = publication.renderer.presentationSize(forMaxDisplaySize: size)
        guard dimensions != publication.size else { return }
        let producer = publication.producer
        guard let fence = producer.createFence() else { throw Error.couldNotCreateFence }
        let operation = publication.nextOperation
        try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
            host.prepareOperation(presentationID: presentationID, operationID: operation, kind: "resize",
                                  contextID: producer.contextID, width: dimensions.width, height: dimensions.height,
                                  fencePayload: fence.payload(), reply: reply)
        }
        guard self.publication?.producer === producer else { return }
        producer.setFence(fence)
        try await publication.renderer.resize(producer: producer, isActive: true, size: dimensions)
        guard self.publication?.producer === producer else { return }
        self.publication?.size = dimensions
        try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
            host.completeOperation(presentationID: presentationID, operationID: operation, reply: reply)
        }
        if self.publication?.producer === producer { self.publication?.nextOperation += 1 }
    }

    func willEndStream() {
        guard !isInvalidated else { return }
        setCursorWindowID(nil)
        stopVideo()
        isInvalidated = true
        publisher?.endStream(self)
    }

    func resetHostState() {
        frameSourceID = nil
        latestVideoFrame = nil
        stopVideo()
        let previous = publication
        publication = nil
        isPublished = false
        guard let previous else { return }
        previous.producer.invalidate()
        Task { await previous.renderer.stop() }
    }

    func performAction(_ action: RemoteHostedPIPContentAction) {
        switch action {
        case .custom("dom-video-start"):
            guard !isInvalidated else { return }
            videoEnabled = true
            sendVideoFrameIfReady()
        case .custom("dom-video-stop"):
            stopVideo()
        case .focusPresentation:
            publication?.renderer.focusPresentation()
        default:
            break
        }
    }

    private func stopVideo() {
        videoEnabled = false
        inFlightVideoID = nil
        videoEncoder = nil
    }

    private func sendVideoFrameIfReady() {
        guard videoEnabled, inFlightVideoID == nil, isPublished, !isInvalidated,
              let publisher, let connection = publisher.transport.connection,
              let frame = latestVideoFrame else { return }
        let id = UUID()
        let connectionID = ObjectIdentifier(connection)
        inFlightVideoID = id
        do {
            if videoEncoder?.sourceWidth != CVPixelBufferGetWidth(frame)
                || videoEncoder?.sourceHeight != CVPixelBufferGetHeight(frame)
                || videoEncoder?.maxPixelDimension != maxVideoPixelDimension {
                videoEncoder = nil
                videoEncoder = try RemoteHostedPIPVideoEncoder(source: frame, maxPixelDimension: maxVideoPixelDimension)
            }
            try videoEncoder?.encode(frame) { [weak self] result in
                Task { @MainActor in await self?.deliverVideo(result, id: id, connectionID: connectionID) }
            }
        } catch {
            stopVideo()
            publisher.transport.recordFailure("Video frame encoding failed", error: error)
        }
    }

    private func deliverVideo(_ result: Result<RemoteHostedPIPVideoFrame, Swift.Error>, id: UUID,
                              connectionID: ObjectIdentifier) async {
        guard inFlightVideoID == id, isPublished, !isInvalidated, let publisher,
              publisher.streamsByPresentationID[presentationID] === self,
              let connection = publisher.transport.connection, ObjectIdentifier(connection) == connectionID else { return }
        defer { if inFlightVideoID == id { inFlightVideoID = nil } }
        do {
            let frame = try result.get()
            try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
                host.publishFrame(presentationID: presentationID, videoData: frame.videoData,
                                  decoderConfiguration: frame.decoderConfiguration, codec: RemoteHostedPIPVideoFrame.codec,
                                  timestamp: frame.timestamp, isKeyFrame: frame.isKeyFrame, reply: reply)
            }
        } catch {
            guard inFlightVideoID == id else { return }
            stopVideo()
            publisher.transport.recordFailure("Video frame delivery failed", error: error)
        }
    }

    // The publisher owns the end timer.
    func cancelEndStreamTimeout() {}
}

extension RemoteHostedPIPContentPublisher {
    func publishCheckerboardStream(threadID: String, turnID: String) -> RemoteHostedPIPContentStream {
        let stream = RemoteHostedPIPContentStream(publisher: self, threadID: threadID, turnID: turnID) { onFrame in
            RemoteHostedPIPCheckerboardRenderer(onPixelBuffer: onFrame)
        }
        registerExistingStream(stream)
        return stream
    }
}
