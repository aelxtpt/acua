import AppKit
import Combine
import Foundation

enum RemoteHostedPIPContentAction: Equatable {
    case custom(String)
    case focusPresentation
}

// Stream renderers own their graphics effects. The publisher owns host transport.
@MainActor protocol RemoteHostedPIPPublishingStream: AnyObject {
    var presentationID: String { get }
    var isPublished: Bool { get }
    var isInvalidated: Bool { get }
    var maxDisplaySize: CGFloat { get set }
    var maxVideoPixelDimension: Int { get set }
    func resetHostState()
    func publish(to connection: NSXPCConnection) async throws
    func updateMaxDisplaySize(_ size: CGFloat, connection: NSXPCConnection?) async throws
    func performAction(_ action: RemoteHostedPIPContentAction)
    func cancelEndStreamTimeout()
    func applyWindowGeometry() async throws
    var geometryUpdatesManagePresentationSize:Bool { get }
}

extension RemoteHostedPIPPublishingStream {
    func applyWindowGeometry() async throws {}
    var geometryUpdatesManagePresentationSize:Bool { false }
}

@MainActor enum RemoteHostedPIPPetLocation {
    static private(set) var position: CGPoint?
    static func set(x: Double, y: Double, available: Bool) { position = available ? CGPoint(x: x, y: y) : nil }
    static func clear() { position = nil }
}

@MainActor
final class RemoteHostedPIPService {
    private let isEnabled: @MainActor () -> Bool
    private(set) var publisher: RemoteHostedPIPContentPublisher?

    init(isEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
    }

    func prepare() {
        guard publisher == nil, isEnabled() else { return }
        let publisher = RemoteHostedPIPContentPublisher()
        publisher.start()
        self.publisher = publisher
    }

    func endpoint() -> NSXPCListenerEndpoint? {
        prepare()
        return publisher?.endpointForHostConnection()
    }
}

@MainActor final class RemoteHostedPIPContentPublisher: NSObject, ObservableObject, RemoteHostedPIPConnectionOwner {
    private enum Error: Swift.Error, CustomNSError {
        case presentationUnavailable
        static var errorDomain: String {
            let name = String(reflecting: Self.self)
            let suffix = name[name.range(of: ".RemoteHostedPIPContentPublisher.")!.lowerBound...]
            return "ComputerUse" + suffix
        }
        var errorCode: Int { 1 }
        var errorUserInfo: [String: Any] { [:] }
    }

    @Published private(set) var connectionDiagnostics = RemoteHostedPIPContentConnectionDiagnostics()
    private(set) var transport: RemoteHostedPIPConnection!
    private let operationQueue = AsyncSerialQueue()
    private var diagnosticsObservation: AnyCancellable?
    private(set) var maxDisplaySize: CGFloat = 200
    private(set) var streamsByPresentationID = [String: any RemoteHostedPIPPublishingStream]()
    private(set) var endingStreamsByPresentationID = [String: any RemoteHostedPIPPublishingStream]()
    private var endTimeouts = [String: Task<Void, Never>]()
    private var computerUseCursorLocation: (point: CGPoint, isActive: Bool)?
    private var cursorUpdateQueued = false
    private var cursorUpdateGeneration: UInt64 = 0

    override init() {
        super.init()
        transport = RemoteHostedPIPConnection(owner: self)
        diagnosticsObservation = transport.$connectionDiagnostics.sink { [weak self] in self?.connectionDiagnostics = $0 }
    }

    func start() { transport.start() }
    func endpointForHostConnection() -> NSXPCListenerEndpoint { transport.endpointForHostConnection() }
    func retryConnection() { transport.retryConnection() }

    func registerExistingStream(_ stream: any RemoteHostedPIPPublishingStream) {
        stream.maxDisplaySize = maxDisplaySize
        streamsByPresentationID[stream.presentationID] = stream
        enqueueStreamReplay()
    }

    func noteInteraction(_ stream: any RemoteHostedPIPPublishingStream) {
        operationQueue.async { @MainActor [weak self, weak stream] in
            guard let self, let stream, stream.isPublished, !stream.isInvalidated,
                  self.streamsByPresentationID[stream.presentationID] === stream,
                  let connection = self.transport.connection else { return }
            do {
                try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
                    host.noteInteraction(presentationID: stream.presentationID, reply: reply)
                }
            } catch { self.transport.recordFailure("Presentation interaction notification failed", error: error) }
        }
    }

    func updateWindowGeometry(_ stream: any RemoteHostedPIPPublishingStream) {
        operationQueue.async { @MainActor [weak self, weak stream] in
            guard let self, let stream, !stream.isInvalidated,
                  self.streamsByPresentationID[stream.presentationID] === stream else { return }
            do {
                try await stream.applyWindowGeometry()
                if !stream.geometryUpdatesManagePresentationSize {
                    try await stream.updateMaxDisplaySize(self.maxDisplaySize, connection: self.transport.connection)
                }
            } catch { self.transport.recordFailure("Window geometry update failed", error: error) }
        }
    }

    func enqueueWindowResize(_ stream:RemoteHostedPIPContentStream,phase:PIPHostResizePhase,size:CGSize) {
        guard streamsByPresentationID[stream.presentationID]===stream else {return}
        let connection=transport.connection
        operationQueue.async { @MainActor [weak self,weak stream] in
            guard let stream,let connection else {return}
            do {try await stream.performWindowResize(phase,size:size,connection:connection)}
            catch {self?.transport.recordFailure(phase.failureMessage,error:error)}
        }
    }

    func registerExistingEndingStream(_ stream: any RemoteHostedPIPPublishingStream) {
        guard streamsByPresentationID[stream.presentationID] === stream else { return }
        streamsByPresentationID.removeValue(forKey: stream.presentationID)
        endingStreamsByPresentationID[stream.presentationID] = stream
    }

    func resetRemoteHostedStreams() {
        endTimeouts.values.forEach { $0.cancel() }
        endTimeouts.removeAll()
        for stream in streamsByPresentationID.values { stream.resetHostState() }
        for stream in endingStreamsByPresentationID.values { stream.resetHostState() }
        endingStreamsByPresentationID.removeAll()
    }

    func clearRemoteHostedPetLocation() { RemoteHostedPIPPetLocation.clear() }

    func enqueueRemoteHostedStreamsAndCursorReplay() {
        enqueueStreamReplay()
        if let cursor = computerUseCursorLocation { enqueueCursor(cursor.point, isActive: cursor.isActive) }
    }

    private func enqueueStreamReplay() {
        operationQueue.async { @MainActor [weak self] in
            guard let self, let connection = self.transport.connection else { return }
            let streams = self.streamsByPresentationID
            for stream in streams.values where !stream.isPublished && !stream.isInvalidated {
                do { try await stream.publish(to: connection) }
                catch {
                    self.transport.recordFailure("Presentation publication failed", error: error)
                    stream.resetHostState()
                }
            }
        }
    }

    func setComputerUseCursorLocation(_ point: CGPoint, isActive: Bool, coalescing: Bool = false) {
        computerUseCursorLocation = (point, isActive)
        guard coalescing else {
            cursorUpdateGeneration &+= 1
            cursorUpdateQueued = false
            enqueueCursor(point, isActive: isActive)
            return
        }
        guard !cursorUpdateQueued else { return }
        cursorUpdateQueued = true
        let generation = cursorUpdateGeneration
        operationQueue.async { @MainActor [weak self] in
            guard let self, self.cursorUpdateGeneration == generation else { return }
            self.cursorUpdateQueued = false
            guard let cursor = self.computerUseCursorLocation, cursor.isActive else { return }
            await self.sendCursor(cursor.point, isActive: true)
        }
    }

    private func enqueueCursor(_ point: CGPoint, isActive: Bool) {
        operationQueue.async { @MainActor [weak self] in
            await self?.sendCursor(point, isActive: isActive)
        }
    }

    private func sendCursor(_ point: CGPoint, isActive: Bool) async {
        guard let connection = transport.connection else { return }
        do {
            try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
                host.setComputerUseCursorLocation(x: point.x, y: point.y, isActive: isActive, reply: reply)
            }
        } catch { transport.recordFailure("Cursor location notification failed", error: error) }
    }

    static func normalizedMaxDisplaySize(_ size: Double) -> CGFloat {
        guard size.isFinite else { return 200 }
        return CGFloat(min(400, max(100, size.rounded(.toNearestOrAwayFromZero))))
    }

    private func updateDisplaySize(_ size: Double) {
        let value = Self.normalizedMaxDisplaySize(size)
        guard value != maxDisplaySize else { return }
        maxDisplaySize = value
        let connection = transport.connection
        for stream in streamsByPresentationID.values {
            operationQueue.async { @MainActor [weak self, weak stream] in
                guard let stream else { return }
                do { try await stream.updateMaxDisplaySize(value, connection: connection) }
                catch { self?.transport.recordFailure("Maximum display size update failed", error: error) }
            }
        }
    }

    private func updateVideoDimension(_ dimension: Double, presentationID: String) throws {
        guard dimension.isFinite, let stream = streamsByPresentationID[presentationID], !stream.isInvalidated else {
            throw Error.presentationUnavailable
        }
        stream.maxVideoPixelDimension = Int(min(720, max(2, ceil(dimension))))
    }

    private func performStreamAction(presentationID: String, kind: String) throws {
        let ending = kind == "focus-presentation" ? endingStreamsByPresentationID[presentationID] : nil
        let videoAction = kind == "dom-video-start" || kind == "dom-video-stop"
        guard let stream = streamsByPresentationID[presentationID] ?? ending,
              stream.isPublished || videoAction,
              !stream.isInvalidated || (ending != nil && stream === ending) else { throw Error.presentationUnavailable }
        stream.performAction(kind == "focus-presentation" ? .focusPresentation : .custom(kind))
    }

    private func finishEndingStream(_ stream: any RemoteHostedPIPPublishingStream) {
        guard endingStreamsByPresentationID[stream.presentationID] === stream else { return }
        endingStreamsByPresentationID.removeValue(forKey: stream.presentationID)
        endTimeouts.removeValue(forKey: stream.presentationID)?.cancel()
        stream.cancelEndStreamTimeout()
        stream.resetHostState()
    }

    func endStream(_ stream: any RemoteHostedPIPPublishingStream) {
        let id = stream.presentationID
        guard streamsByPresentationID[id] === stream else { return }
        registerExistingEndingStream(stream)
        operationQueue.async { @MainActor [weak self, weak stream] in
            guard let self, let stream, self.endingStreamsByPresentationID[id] === stream else { return }
            guard stream.isPublished, let connection = self.transport.connection else {
                self.finishEndingStream(stream)
                return
            }
            do {
                try await RemoteHostedPIPXPC.callHost(on: connection) { host, reply in
                    host.willEndStream(presentationID: id, reply: reply)
                }
            } catch {
                self.transport.recordFailure("Will end presentation failed", error: error)
                self.finishEndingStream(stream)
                return
            }
            guard self.endingStreamsByPresentationID[id] === stream else { return }
            self.endTimeouts[id] = Task { @MainActor [weak self, weak stream] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if let stream { self?.finishEndingStream(stream) }
            }
        }
    }

    nonisolated func connect(reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor [weak self] in self?.transport.didCompleteHandshake() }
        reply(nil)
    }

    nonisolated func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor [weak self] in self?.updateDisplaySize(size); reply(nil) }
    }

    nonisolated func setVideoMaxPixelDimension(_ dimension: Double, presentationID: String, reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor [weak self] in
            do { try self?.updateVideoDimension(dimension, presentationID: presentationID); reply(nil) }
            catch { reply(error as NSError) }
        }
    }

    nonisolated func performAction(presentationID: String, kind: String, reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor [weak self] in
            do { try self?.performStreamAction(presentationID: presentationID, kind: kind); reply(nil) }
            catch { reply(error as NSError) }
        }
    }

    nonisolated func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor [weak self] in
            if let self, let stream = self.endingStreamsByPresentationID[presentationID] { self.finishEndingStream(stream) }
            reply(nil)
        }
    }

    nonisolated func setPetLocation(x: Double, y: Double, available: Bool, reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor in RemoteHostedPIPPetLocation.set(x: x, y: y, available: available); reply(nil) }
    }
}
