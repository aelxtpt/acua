import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

@MainActor
protocol RemoteHostedPIPStreamRenderer: AnyObject {
    var sourceProcessIdentifier: Int32? { get }
    var nativeAssociatedWindowUpdate: (([CGWindowID])->Void)? { get }
    func presentationSize(forMaxDisplaySize size: CGFloat) -> CGSize
    func setAssociatedWindowIDs(_ ids: [CGWindowID])
    func setCursorWindowID(_ id: CGWindowID?)
    func setGeometryChangeHandler(_ handler: @escaping () -> Void)
    func setSourceUnavailableHandler(_ handler: @escaping () -> Void)
    func refreshGeometry() async throws
    var emitsNativeGeometryResizeCallbacks:Bool { get }
    func setGeometryResizeHandlers(changed:@escaping(CGSize)->Void,settled:@escaping(CGSize)->Void)
    func setFrameDeliverySuspended(_ value:Bool)
    func resize(producer:RemoteHostedPIPContentProducer,layoutGeneration:UInt64,size:CGSize) async throws
    func focusPresentation()
    func prepare(producer: RemoteHostedPIPContentProducer, isActive: Bool, maxDisplaySize: CGFloat) async throws -> CGSize
    func resize(producer: RemoteHostedPIPContentProducer, isActive: Bool, size: CGSize) async throws
    func stop() async
}

extension RemoteHostedPIPStreamRenderer {
    var sourceProcessIdentifier: Int32? { nil }
    var nativeAssociatedWindowUpdate: (([CGWindowID])->Void)? { nil }
    func setAssociatedWindowIDs(_ ids: [CGWindowID]) {}
    func setCursorWindowID(_ id: CGWindowID?) {}
    func setGeometryChangeHandler(_ handler: @escaping () -> Void) {}
    func setSourceUnavailableHandler(_ handler: @escaping () -> Void) {}
    func refreshGeometry() async throws {}
    var emitsNativeGeometryResizeCallbacks:Bool { false }
    func setGeometryResizeHandlers(changed:@escaping(CGSize)->Void,settled:@escaping(CGSize)->Void) {}
    func setFrameDeliverySuspended(_ value:Bool) {}
    func resize(producer:RemoteHostedPIPContentProducer,layoutGeneration:UInt64,size:CGSize) async throws {
        try await resize(producer:producer,isActive:true,size:size)
    }
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
        case missingPublication = 1

        static var errorDomain: String { "ComputerUse.RemoteHostedPIPContentStream.Error" }
        var errorCode: Int { rawValue }
        var errorUserInfo: [String: Any] { [:] }
    }

    private struct Publication {
        let producer: RemoteHostedPIPContentProducer
        let renderer: any RemoteHostedPIPStreamRenderer
        var size: CGSize
    }

    let presentationID = UUID().uuidString
    let threadID: String
    let turnID: String
    private weak var publisher: RemoteHostedPIPContentPublisher?
    private let makeRenderer: (@escaping (CVPixelBuffer) -> Void) -> any RemoteHostedPIPStreamRenderer
    private var publication: Publication?
    private var layoutGeneration:UInt64=0
    private var nextOperationID:UInt64=1
    private var presentationSize=CGSize(width:200,height:200)
    var geometryUpdatesManagePresentationSize:Bool { publication?.renderer.emitsNativeGeometryResizeCallbacks ?? false }
    private var associatedWindowIDs:[CGWindowID]=[]
    private weak var currentRenderer:(any RemoteHostedPIPStreamRenderer)?
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
        guard let publisher else { throw Error.missingPublication }
        guard !isInvalidated, publication == nil, publisher.transport.connection === connection else { return }
        let producer = try RemoteHostedPIPContentProducer()
        let sourceID = UUID()
        frameSourceID = sourceID
        let renderer = makeRenderer { [weak self] pixels in
            guard let self, self.frameSourceID == sourceID, !self.isInvalidated else { return }
            self.latestVideoFrame = pixels
            self.sendVideoFrameIfReady()
        }
        currentRenderer=renderer
        if !renderer.emitsNativeGeometryResizeCallbacks {
            renderer.setGeometryChangeHandler { [weak self] in
                guard let self,self.frameSourceID==sourceID else { return };self.requestGeometryUpdate()
            }
        }
        renderer.setGeometryResizeHandlers(changed:{ [weak self] in self?.geometryDidChange($0) },
            settled:{ [weak self] in self?.geometryDidSettle($0) })
        renderer.setSourceUnavailableHandler { [weak self] in self?.willEndStream() }
        let initialWindowIDs = associatedWindowIDs
        let size: CGSize
        do {
            renderer.setAssociatedWindowIDs(initialWindowIDs)
            size = try await renderer.prepare(producer: producer, isActive: true, maxDisplaySize: maxDisplaySize)
        } catch {
            if currentRenderer===renderer {currentRenderer=nil}
            producer.invalidate()
            await renderer.stop()
            throw error
        }
        guard !isInvalidated, frameSourceID == sourceID, publisher.transport.connection === connection else {
            if currentRenderer===renderer {currentRenderer=nil}
            producer.invalidate()
            await renderer.stop()
            return
        }
        publication = Publication(producer: producer, renderer: renderer, size: size)
        presentationSize=size
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

    func setAssociatedWindowIDs(_ ids:[CGWindowID]) {
        PIPAssociatedWindowState.update(ids,current:{ [self] in associatedWindowIDs },
            store:{ [self] in associatedWindowIDs=$0 },forward:{ [self] in currentRenderer?.nativeAssociatedWindowUpdate?($0) })
    }
    var diagnosticAssociatedWindowIDs:[CGWindowID] {associatedWindowIDs}

    private func requestGeometryUpdate() {
        guard !geometryRefreshQueued, !isInvalidated, let publisher else { return }
        geometryRefreshQueued = true
        publisher.updateWindowGeometry(self)
    }

    func applyWindowGeometry() async throws {
        geometryRefreshQueued=false
        try await publication?.renderer.refreshGeometry()
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

    private func geometryDidChange(_ size:CGSize) {
        guard isPublished,!isInvalidated else { return }
        publication?.renderer.setFrameDeliverySuspended(true)
        publisher?.enqueueWindowResize(self,phase:.changed,size:size)
    }
    private func geometryDidSettle(_ size:CGSize) {
        guard isPublished,!isInvalidated else { return }
        publisher?.enqueueWindowResize(self,phase:.settled,size:size)
    }
    var diagnosticHostTransactionState:[String:Any] {
        var value:[String:Any]=["published":isPublished,"invalidated":isInvalidated,"layoutGeneration":String(layoutGeneration),
            "nextOperation":String(nextOperationID),"size":[Double(presentationSize.width),Double(presentationSize.height)]]
        if let publication {
            let size=publication.producer.rootLayer.frame.size
            value["rootSize"]=[Double(size.width),Double(size.height)]
            value["contextID"]=publication.producer.contextID
        }
        return value
    }
    func performWindowResize(_ phase:PIPHostResizePhase,size:CGSize,connection:NSXPCConnection) async throws {
        typealias Transaction=PIPHostResizeTransaction<RemoteHostedPIPContentProducer,any RemoteHostedPIPStreamRenderer,RemoteHostedPIPContentFence>
        let transaction=Transaction(environment:.init(snapshot:{ [self] phase in
            guard let publisher,let publication,isPublished,!isInvalidated else {throw Error.missingPublication}
            return .init(owner:publisher,producer:publication.producer,renderer:publication.renderer)
        },missingState:{Error.missingPublication},missingFence:{Error.couldNotCreateFence},
            createFence:{$0.createFence()},operation:{ [self] in nextOperationID },contextID:{$0.contextID},
            prepare:{ [self] kind,operation,contextID,size,fence in
                try await RemoteHostedPIPXPC.callHost(on:connection) { host,reply in
                    host.prepareOperation(presentationID:presentationID,operationID:operation,kind:kind,contextID:contextID,
                        width:size.width,height:size.height,fencePayload:fence.payload(),reply:reply)
                }
            },setFence:{$0.setFence($1)},nextLayoutGeneration:{ [self] in layoutGeneration+1 },
            resize:{ renderer,producer,generation,size in try await renderer.resize(producer:producer,layoutGeneration:generation,size:size) },
            didResize:{ [self] size in presentationSize=size;publication?.size=size;layoutGeneration += 1 },
            complete:{ [self] operation in
                try await RemoteHostedPIPXPC.callHost(on:connection) { host,reply in
                    host.completeOperation(presentationID:presentationID,operationID:operation,reply:reply)
                }
            },releaseFence:{$0.release()},advanceOperation:{ [self] in nextOperationID += 1 },resume:{$0.setFrameDeliverySuspended(false)}))
        try await transaction.perform(phase,size:size)
    }
    func updateMaxDisplaySize(_ size: CGFloat, connection: NSXPCConnection?) async throws {
        let normalized=PIPDisplaySizePolicy.normalizedMaximum(size)
        maxDisplaySize=normalized
        guard isPublished,!isInvalidated,let publication,let connection else{return}
        let dimensions=publication.renderer.presentationSize(forMaxDisplaySize:normalized)
        guard PIPDisplaySizePolicy.requiresResize(current:presentationSize,next:dimensions) else{return}
        try await performWindowResize(.settled,size:dimensions,connection:connection)
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
        currentRenderer=nil
        isPublished = false
        presentationSize=CGSize(width:200,height:200);layoutGeneration=0;nextOperationID=1
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
