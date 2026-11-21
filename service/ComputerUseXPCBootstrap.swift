import Carbon
import Foundation
import XPC

@MainActor
final class ComputerUseXPCBootstrap: NSObject {
    static let eventClass: AEEventClass = 0x41784375 // AxCu
    static let bootstrap: AEEventID = 0x58706342 // XpcB
    static let bootstrapNoReply: AEEventID = 0x5870634e // XpcN
    static let pipBootstrap: AEEventID = 0x42506950 // BPiP
    static let pipBootstrapNoReply: AEEventID = 0x4e506950 // NPiP
    static let requestEvent: AEEventID = 0x52646e53 // RdnS
    static let requestTypeProperty: AEKeyword = 0x54707352 // TpsR
    static let requestDataProperty: AEKeyword = 0x44716552 // DqeR
    static let requestMetadataProperty: AEKeyword = 0x644d7843 // dMxC
    static let versionProperty: AEKeyword = 0x436c566e // ClVn
    static let clientTypeProperty: AEKeyword = 0x436c5479 // ClTy
    private static let replyPortType: DescType = 0x706f7274 // port

    var onPeerAdmitted: (pid_t) -> Void = { _ in }

    private var sessions = [UUID: ComputerUseXPCSession]()
    private var handshakes = 0
    private var suspendedEvents = [UUID: NSAppleEventManager.SuspensionID]()
    private let allow: (PeerAuditCredentials) -> Bool
    private let dispatch: @Sendable (PeerAuditCredentials, SenderRequestContext?, String, Data?, Data?, [FileHandle], Bool, @escaping () -> Bool) throws -> Data
    private let resolveSenderContext: (Int32) -> SenderRequestContext?
    private let authorizeEvent: ((AppleEventAuthorization.Sender) throws -> SenderRequestContext)?
    private let foreground: ComputerUseForegroundUpdates
    private let pipEndpoint: @MainActor () -> NSXPCListenerEndpoint?

    init(allow: @escaping (PeerAuditCredentials) -> Bool,
         dispatch: @escaping @Sendable (PeerAuditCredentials, SenderRequestContext?, String, Data?, Data?, [FileHandle], Bool, @escaping () -> Bool) throws -> Data,
         foreground: ComputerUseForegroundUpdates,
         pipEndpoint: @escaping @MainActor () -> NSXPCListenerEndpoint? = { nil },
         resolveSenderContext: @escaping (Int32) -> SenderRequestContext? = SenderRequestContext.resolveNative,
         authorizeEvent: ((AppleEventAuthorization.Sender) throws -> SenderRequestContext)? = nil) {
        self.allow = allow
        self.dispatch = dispatch
        self.foreground = foreground
        self.pipEndpoint = pipEndpoint
        self.resolveSenderContext = resolveSenderContext
        self.authorizeEvent = authorizeEvent
    }

    func install() {
        for event in [Self.bootstrap, Self.bootstrapNoReply] {
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receive(_:reply:)),
                forEventClass: Self.eventClass, andEventID: event)
        }
        for event in [Self.pipBootstrap, Self.pipBootstrapNoReply] {
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receivePIP(_:reply:)),
                forEventClass: Self.eventClass, andEventID: event)
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receiveRequest(_:reply:)),
            forEventClass: Self.eventClass, andEventID: Self.requestEvent)
    }

    func stop() {
        for event in [Self.bootstrap, Self.bootstrapNoReply, Self.pipBootstrap, Self.pipBootstrapNoReply, Self.requestEvent] {
            NSAppleEventManager.shared().removeEventHandler(forEventClass: Self.eventClass, andEventID: event)
        }
        let old = Array(sessions.values)
        sessions.removeAll()
        old.forEach { $0.invalidate() }
    }

    @objc func receiveRequest(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor?) {
        do {
            let authenticated = try authenticatedSender(event)
            let peer = authenticated.peer
            let job = try requestJob(event, authenticatedPeer: peer, senderContext: authenticated.context)
            onPeerAdmitted(peer.pid)
            guard suspendedEvents.count < 128 else {
                throw ServiceError(.unknownError, "Computer Use Apple Event request limit reached")
            }
            let id = try suspendEvent()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result { try job() }.mapError(ComputerUseXPC.requestError)
                DispatchQueue.main.async { self.finishEvent(id, result) }
            }
        } catch {
            Self.writeRequestReply(.failure(ComputerUseXPC.requestError(error)), to: reply)
        }
    }

    private func suspendEvent() throws -> UUID {
        guard let suspension = NSAppleEventManager.shared().suspendCurrentAppleEvent() else {
            throw ServiceError(.unknownError, "Could not suspend Computer Use Apple event")
        }
        let id = UUID()
        suspendedEvents[id] = suspension
        return id
    }

    private func finishEvent(_ id: UUID, _ result: Result<Data, NSError>?) {
        guard let suspension = suspendedEvents.removeValue(forKey: id) else { return }
        let manager = NSAppleEventManager.shared()
        if let result {
            Self.writeRequestReply(result, to: manager.replyAppleEvent(forSuspensionID: suspension))
        }
        manager.resume(withSuspensionID: suspension)
    }

    func requestJob(_ event: NSAppleEventDescriptor, authenticatedPeer peer: PeerAuditCredentials,
                    senderContext: SenderRequestContext? = nil) throws -> @Sendable () throws -> Data {
        let senderContext = senderContext ?? resolveSenderContext(peer.pid)?.withAppleEventMetadata(
            clientType: event.paramDescriptor(forKeyword: Self.clientTypeProperty)?.stringValue,
            version: event.paramDescriptor(forKeyword: Self.versionProperty)?.stringValue)
        try Self.validateVersion(event)
        guard let request = event.paramDescriptor(forKeyword: Self.requestDataProperty)?.data else {
            throw ServiceError(.couldNotGetRequestData, "Could not get request data")
        }
        guard let type = event.paramDescriptor(forKeyword: Self.requestTypeProperty)?.stringValue else {
            throw ServiceError(.couldNotGetRequestTypeName, "Could not get request type name from Apple event")
        }
        let metadata = event.paramDescriptor(forKeyword: Self.requestMetadataProperty)?.data
        let returnActionAppSnapshot = senderContext?.clientMetadata.returnsActionAppSnapshot ?? Self.returnsActionAppSnapshot(for: event)
        let dispatch = self.dispatch
        return {
            guard senderContext?.foregroundOnly != true else {
                throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
            }
            return try dispatch(peer, senderContext, type, request, metadata, [], returnActionAppSnapshot, { false })
        }
    }

    static func writeRequestReply(_ result: Result<Data, NSError>, to reply: NSAppleEventDescriptor?) {
        guard let reply, reply.descriptorType != DescType(typeNull) else { return }
        switch result {
        case .success(let data):
            if let descriptor = NSAppleEventDescriptor(descriptorType: DescType(typeData), data: data) {
                reply.setParam(descriptor, forKeyword: AEKeyword(keyDirectObject))
            }
        case .failure(let error):
            reply.setParam(NSAppleEventDescriptor(int32: Int32(clamping: error.code)), forKeyword: AEKeyword(keyErrorNumber))
            reply.setParam(NSAppleEventDescriptor(string: error.localizedDescription), forKeyword: AEKeyword(keyErrorString))
        }
    }

    @objc func receivePIP(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor?) {
        let noReply = event.eventID == Self.pipBootstrapNoReply
        do {
            let authenticated = try authenticatedSender(event)
            let peer = authenticated.peer
            guard authenticated.context?.foregroundOnly != true else {
                throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
            }
            guard handshakes < 128, suspendedEvents.count < 128 else {
                throw ServiceError(.unknownError, "Computer Use XPC session limit reached")
            }
            let endpoint = try endpointForPIPEvent(event)
            onPeerAdmitted(peer.pid)
            let port = try Self.retainedReplyPort(event)
            let id: UUID
            do { id = try suspendEvent() }
            catch {
                mach_port_deallocate(mach_task_self_, port)
                throw error
            }
            handshakes += 1
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { mach_port_deallocate(mach_task_self_, port) }
                let sent = ComputerUseXPCMachReply.send(endpoint, port: port, noReply: noReply)
                let failure = sent ? nil : ComputerUseXPC.error(.unknownError, "Could not send the Computer Use bootstrap response.")
                if noReply, let failure {
                    _ = ComputerUseXPCMachReply.send(nil, port: port, noReply: true, error: failure)
                }
                DispatchQueue.main.async {
                    self.handshakes -= 1
                    self.finishEvent(id, failure.map { .failure($0) })
                }
            }
        } catch {
            rejectBootstrap(error, event: event, reply: reply, noReply: noReply)
        }
    }

    func endpointForPIPEvent(_ event: NSAppleEventDescriptor) throws -> NSXPCListenerEndpoint {
        try Self.validateVersion(event)
        guard let endpoint = pipEndpoint() else {
            throw ServiceError(.unknownError, "Remote hosted PiP is unavailable.")
        }
        return endpoint
    }

    @objc func receive(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor?) {
        let noReply = event.eventID == Self.bootstrapNoReply
        do {
            let authenticated = try authenticatedSender(event)
            let peer = authenticated.peer
            let senderContext = authenticated.context
            try Self.validateVersion(event)
            guard sessions.count < 128, handshakes < 128 else {
                throw ServiceError(.unknownError, "Computer Use XPC session limit reached")
            }
            let port = try Self.retainedReplyPort(event)
            let id = UUID()
            let dispatch = self.dispatch
            let returnActionAppSnapshot = senderContext?.clientMetadata.returnsActionAppSnapshot ?? Self.returnsActionAppSnapshot(for: event)
            let session = ComputerUseXPCSession(peerPID: peer.pid, peerUID: peer.uid, handler: {
                try dispatch(peer, senderContext, $0, $1, $2, $3, returnActionAppSnapshot, $4)
            }, foreground: foreground, foregroundOnly: senderContext?.foregroundOnly ?? false, finished: { [weak self] in
                Task { @MainActor in self?.sessions.removeValue(forKey: id) }
            })
            sessions[id] = session
            onPeerAdmitted(peer.pid)
            handshakes += 1
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { mach_port_deallocate(mach_task_self_, port) }
                if !ComputerUseXPCMachReply.send(session.endpoint, port: port, noReply: noReply) {
                    session.invalidate()
                }
                Task { @MainActor in self?.handshakes -= 1 }
            }
            Task { @MainActor [weak session] in
                try? await Task.sleep(for: .seconds(15))
                session?.invalidateIfUnconnected()
            }
        } catch {
            rejectBootstrap(error, event: event, reply: reply, noReply: noReply)
        }
    }

    private func rejectBootstrap(_ error: Error, event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor?, noReply: Bool) {
        let failure = ComputerUseXPC.requestError(error)
        if noReply, handshakes < 128, let port = try? Self.retainedReplyPort(event) {
            handshakes += 1
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { mach_port_deallocate(mach_task_self_, port) }
                _ = ComputerUseXPCMachReply.send(nil, port: port, noReply: true, error: failure)
                Task { @MainActor in self?.handshakes -= 1 }
            }
        }
        Self.writeRequestReply(.failure(failure), to: reply)
    }

    func authenticatedSender(_ event: NSAppleEventDescriptor) throws -> (peer: PeerAuditCredentials, context: SenderRequestContext?) {
        if let authorizeEvent {
            let sender = AppleEventAuthorization.Sender(
                pid: event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
                auditData: event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
                version: event.paramDescriptor(forKeyword: Self.versionProperty)?.stringValue,
                clientType: event.paramDescriptor(forKeyword: Self.clientTypeProperty)?.stringValue)
            do {
                let context = try authorizeEvent(sender)
                guard let pid = sender.pid, context.senderPID == pid else { throw AppleEventAuthorization.Failure.notAuthenticated }
                let data = sender.auditData ?? Data()
                let uid = data.count == MemoryLayout<audit_token_t>.size
                    ? data.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self).val.1 } : geteuid()
                return (.init(pid: pid, uid: uid, auditToken: data), context)
            } catch let failure as AppleEventAuthorization.Failure {
                switch failure {
                case .missingSenderPID: throw ServiceError(.couldNotGetSenderPID, "Could not get sender PID from Apple event")
                case .teamNotFound: throw ServiceError(.unknownError, "teamNotFound")
                case .notAuthenticated: throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
                }
            }
        }
        // Explicitly injected legacy allow closures remain useful to transport
        // fixtures. Production installs the complete Apple Event authorizer.
        let peer = try Self.credentials(event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
            senderPID: event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value)
        guard allow(peer) else {
            throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
        }
        return (peer, resolveSenderContext(peer.pid)?.withAppleEventMetadata(
            clientType: event.paramDescriptor(forKeyword: Self.clientTypeProperty)?.stringValue,
            version: event.paramDescriptor(forKeyword: Self.versionProperty)?.stringValue))
    }

    static func credentials(_ data: Data?, senderPID: pid_t? = nil) throws -> PeerAuditCredentials {
        guard let data, data.count == MemoryLayout<audit_token_t>.size else {
            throw ServiceError(.couldNotGetSenderPID, "Could not get sender PID from Apple event")
        }
        let token = data.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        let pid = Int32(bitPattern: token.val.5)
        guard pid > 0 else { throw ServiceError(.couldNotGetSenderPID, "Could not get sender PID from Apple event") }
        if let senderPID, senderPID != pid {
            throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
        }
        return PeerAuditCredentials(pid: pid, uid: token.val.1, auditToken: data)
    }

    private static func validateVersion(_ event: NSAppleEventDescriptor) throws {
        try validateVersion(event.paramDescriptor(forKeyword: versionProperty)?.stringValue,
                            clientType: event.paramDescriptor(forKeyword: clientTypeProperty)?.stringValue)
    }

    static func returnsActionAppSnapshot(for event: NSAppleEventDescriptor) -> Bool {
        SenderClientMetadata.ClientType.parse(event.paramDescriptor(forKeyword: clientTypeProperty)?.stringValue) != .nodeRepl
    }

    static func validateVersion(_ version: String?, clientType: String?) throws {
        guard SenderClientMetadata.appleEvent(clientType: clientType, version: version).acceptsVersion(version, ipcVersion: kApiVersion) else {
            throw ServiceError(.incompatibleClientVersion,
                "The Computer Use server and client have a version mismatch. To use Computer Use, ask the user to relaunch their agent app so that the client will be updated to the latest version.")
        }
    }

    private static func retainedReplyPort(_ event: NSAppleEventDescriptor) throws -> mach_port_t {
        guard let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keyReplyPortAttr)),
              descriptor.descriptorType == replyPortType,
              descriptor.data.count == MemoryLayout<mach_port_t>.size else {
            throw ServiceError(.couldNotGetBootstrapPort, "Could not get XPC bootstrap mach port from Apple event")
        }
        let port = descriptor.data.withUnsafeBytes { $0.loadUnaligned(as: mach_port_t.self) }
        var type: mach_port_type_t = 0
        guard mach_port_type(mach_task_self_, port, &type) == KERN_SUCCESS, type & 0x10000 != 0,
              mach_port_mod_refs(mach_task_self_, port, mach_port_right_t(MACH_PORT_RIGHT_SEND), 1) == KERN_SUCCESS else {
            throw ServiceError(.couldNotGetBootstrapPort, "Could not get XPC bootstrap mach port from Apple event")
        }
        return port
    }
}

enum ComputerUseXPCMachReply {
    private typealias CreatePipe = @convention(c) (mach_port_t, UInt64) -> Unmanaged<AnyObject>?
    private typealias Send = @convention(c) (AnyObject, AnyObject) -> Int32
    private typealias SendWithReply = @convention(c) (AnyObject, AnyObject, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> Int32
    private static let process = dlopen(nil, RTLD_LAZY)

    static func send(_ endpoint: NSXPCListenerEndpoint?, port: mach_port_t, noReply: Bool, error: NSError? = nil) -> Bool {
        guard (endpoint != nil && error == nil) || (endpoint == nil && noReply && error != nil) else { return false }
        guard let process, let create = dlsym(process, "xpc_pipe_create_from_port"),
              let pipe = unsafeBitCast(create, to: CreatePipe.self)(port, 0)?.takeRetainedValue() else { return false }
        let payload = xpc_dictionary_create(nil, nil, 0)
        if let error {
            xpc_dictionary_set_int64(payload, "errorCode", Int64(error.code))
            xpc_dictionary_set_string(payload, "errorMessage", error.localizedDescription)
        }
        if let endpoint {
            let selector = NSSelectorFromString("_endpoint")
            guard endpoint.responds(to: selector),
                  let raw = endpoint.perform(selector)?.takeUnretainedValue() as? ComputerUseXPCFileArray,
                  xpc_get_type(raw) == XPC_TYPE_ENDPOINT else { return false }
            xpc_dictionary_set_value(payload, "endpoint", raw)
        }
        if noReply {
            guard let fn = dlsym(process, "xpc_pipe_simpleroutine") else { return false }
            return unsafeBitCast(fn, to: Send.self)(pipe, payload) == 0
        }
        guard let fn = dlsym(process, "xpc_pipe_routine") else { return false }
        var response: Unmanaged<AnyObject>?
        let result = unsafeBitCast(fn, to: SendWithReply.self)(pipe, payload, &response)
        response?.release()
        return result == 0 && response != nil
    }
}
