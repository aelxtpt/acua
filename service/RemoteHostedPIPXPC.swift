import Foundation
import os
import XPC

typealias RemoteHostedPIPReply = (NSError?) -> Void
typealias RemoteHostedPIPFencePayload = NSObject & OS_xpc_object

@objc(SAIRemoteHostedPIPContentHostXPCProtocol)
protocol RemoteHostedPIPContentHostXPCProtocol {
    @objc(publishPresentationWithID:threadID:turnID:contextID:width:height:withReply:)
    func publishPresentation(id: String, threadID: String, turnID: String, contextID: UInt32,
        width: Double, height: Double, reply: @escaping RemoteHostedPIPReply)
    @objc(setSourceProcessIdentifier:forPresentationWithID:withReply:)
    func setSourceProcessIdentifier(_ pid: Int32, presentationID: String, reply: @escaping RemoteHostedPIPReply)
    @objc(publishFrameWithPresentationID:videoData:decoderConfiguration:codec:timestamp:isKeyFrame:withReply:)
    func publishFrame(presentationID: String, videoData: Data, decoderConfiguration: Data?, codec: String,
        timestamp: UInt64, isKeyFrame: Bool, reply: @escaping RemoteHostedPIPReply)
    @objc(prepareOperationWithPresentationID:operationID:kind:contextID:width:height:fencePayload:withReply:)
    func prepareOperation(presentationID: String, operationID: UInt64, kind: String, contextID: UInt32,
        width: Double, height: Double, fencePayload: RemoteHostedPIPFencePayload, reply: @escaping RemoteHostedPIPReply)
    @objc(completeOperationWithPresentationID:operationID:withReply:)
    func completeOperation(presentationID: String, operationID: UInt64, reply: @escaping RemoteHostedPIPReply)
    @objc(willEndStreamWithPresentationID:withReply:)
    func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply)
    @objc(invalidatePresentationWithID:withReply:)
    func invalidatePresentation(id: String, reply: @escaping RemoteHostedPIPReply)
    @objc(noteInteractionWithPresentationID:withReply:)
    func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply)
    @objc(setComputerUseCursorLocationWithX:y:isActive:withReply:)
    func setComputerUseCursorLocation(x: Double, y: Double, isActive: Bool, reply: @escaping RemoteHostedPIPReply)
}

@objc(SAIRemoteHostedPIPContentProducerXPCProtocol)
protocol RemoteHostedPIPContentProducerXPCProtocol {
    @objc(connectWithReply:)
    func connect(reply: @escaping RemoteHostedPIPReply)
    @objc(setMaxDisplaySize:withReply:)
    func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply)
    @objc(setVideoMaxPixelDimension:forPresentationWithID:withReply:)
    func setVideoMaxPixelDimension(_ dimension: Double, presentationID: String, reply: @escaping RemoteHostedPIPReply)
    @objc(performActionWithPresentationID:kind:withReply:)
    func performAction(presentationID: String, kind: String, reply: @escaping RemoteHostedPIPReply)
    @objc(didEndStreamWithPresentationID:withReply:)
    func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply)
    @objc(setPetLocationWithX:y:available:withReply:)
    func setPetLocation(x: Double, y: Double, available: Bool, reply: @escaping RemoteHostedPIPReply)
}

enum RemoteHostedPIPXPC {
    static let fenceSelector = #selector(RemoteHostedPIPContentHostXPCProtocol.prepareOperation(presentationID:operationID:kind:contextID:width:height:fencePayload:reply:))
    static func hostInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: RemoteHostedPIPContentHostXPCProtocol.self)
        interface.setXPCType(XPC_TYPE_DICTIONARY, for: fenceSelector, argumentIndex: 6, ofReply: false)
        return interface
    }
    static func producerInterface() -> NSXPCInterface {
        NSXPCInterface(with: RemoteHostedPIPContentProducerXPCProtocol.self)
    }

    @MainActor
    static func callHost(on connection: NSXPCConnection,
                         _ send: (RemoteHostedPIPContentHostXPCProtocol, @escaping RemoteHostedPIPReply) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let pending = OSAllocatedUnfairLock(initialState: Optional(continuation))
            let complete: RemoteHostedPIPReply = { error in
                let continuation = pending.withLock { stored in
                    let current = stored
                    stored = nil
                    return current
                }
                if let error { continuation?.resume(throwing: error) }
                else { continuation?.resume() }
            }
            guard let host = connection.remoteObjectProxyWithErrorHandler({ complete($0 as NSError) })
                as? RemoteHostedPIPContentHostXPCProtocol else {
                complete(NSError(domain: "ComputerUse.RemoteHostedPIPContentPublisher.Error", code: 0))
                return
            }
            send(host, complete)
        }
    }
}
