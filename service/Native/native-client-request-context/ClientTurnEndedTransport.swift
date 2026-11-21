import Carbon
import Foundation
import XPC

final class ClientReceivePort: @unchecked Sendable {
    let value: mach_port_t
    private let lock = NSLock()
    private var closed = false

    init() throws {
        var port: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &port) == KERN_SUCCESS else {
            throw ClientTransportFailure.couldNotAllocateBootstrapPort
        }
        guard mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else {
            mach_port_mod_refs(mach_task_self_, port, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
            throw ClientTransportFailure.couldNotAllocateBootstrapPort
        }
        value = port
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        mach_port_mod_refs(mach_task_self_, value, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
    }

    deinit {
        close()
        mach_port_deallocate(mach_task_self_, value)
    }
}

private struct ClientEndpoint: @unchecked Sendable { let value: NSXPCListenerEndpoint }

private final class ClientRequestReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }

    func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

typealias ClientForegroundStream = AsyncThrowingStream<ComputerUseIPCForegroundUpdate, any Error>

private final class ForegroundObserver: NSObject, ClientForegroundObserver, @unchecked Sendable {
    let continuation: ClientForegroundStream.Continuation
    init(_ continuation: ClientForegroundStream.Continuation) { self.continuation = continuation }
    func receiveForegroundContext(_ data: Data) {
        do { continuation.yield(try JSONDecoder().decode(ComputerUseIPCForegroundUpdate.self, from: data)) }
        catch { continuation.finish(throwing: error) }
    }
}

private final class ClientConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let foregroundQueue = DispatchQueue(label: "ComputerUse.foregroundSubscriptions")
    private var invalidated = false
    private var foregroundObservers = [UUID: ForegroundObserver]()

    init(endpoint: NSXPCListenerEndpoint) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = ClientIPCInterface.make()
        connection.invalidationHandler = { [weak self] in self?.markInvalidated() }
        connection.interruptionHandler = { [weak self] in self?.invalidate() }
        connection.activate()
    }

    var isInvalidated: Bool { foregroundQueue.sync { invalidated } }

    private func markInvalidated() {
        foregroundQueue.async {
            self.invalidated = true
            let old = self.foregroundObservers
            self.foregroundObservers = [:]
            for observer in old.values { observer.continuation.finish(throwing: ClientTransportFailure.remoteConnection) }
        }
    }

    func invalidate() {
        connection.invalidate()
        markInvalidated()
    }

    func foregroundUpdates() -> ClientForegroundStream {
        let id = UUID()
        let (stream, continuation) = ClientForegroundStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = ForegroundObserver(continuation)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            foregroundQueue.async { self.removeForegroundObserver(id) }
        }
        foregroundQueue.async { self.registerForegroundObserver(id, observer: observer) }
        return stream
    }

    private func registerForegroundObserver(_ id: UUID, observer: ForegroundObserver) {
        guard !invalidated else { observer.continuation.finish(throwing: ClientTransportFailure.remoteConnection); return }
        foregroundObservers[id] = observer
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in self?.invalidate() }) as? ClientIPCProtocol else {
            observer.continuation.finish(throwing: ClientTransportFailure.missingRemoteProxy); return
        }
        let continuation = observer.continuation
        proxy.subscribeToForegroundContext(id: id as NSUUID, observer: observer) { error in
            if let error { continuation.finish(throwing: error) }
        }
    }

    private func removeForegroundObserver(_ id: UUID) {
        guard foregroundObservers.removeValue(forKey: id) != nil, !invalidated else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? ClientIPCProtocol
        proxy?.unsubscribeFromForegroundContext(id: id as NSUUID)
    }

    func send(type: String, body: Data, metadata: Data? = nil, files: [FileHandle] = []) async throws -> Data {
        let descriptors = xpc_array_create(nil, 0)
        for file in files {
            guard let descriptor = xpc_fd_create(file.fileDescriptor) else { throw ClientTransportFailure.invalidFileDescriptor }
            xpc_array_append_value(descriptors, descriptor)
        }
        defer { withExtendedLifetime(descriptors) {} }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ClientRequestReply(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                reply.finish(.failure(ClientTransportFailure.remoteConnection))
            }) as? ClientIPCProtocol else {
                reply.finish(.failure(ClientTransportFailure.missingRemoteProxy)); return
            }
            proxy.sendRequest(typeName: type, requestData: body, agentMetadataData: metadata,
                fileDescriptors: descriptors as! ClientFileArray) { data, error in
                if let error { reply.finish(.failure(error)) }
                else if let data { reply.finish(.success(data)) }
                else { reply.finish(.failure(ClientTransportFailure.missingResponseData)) }
            }
        }
    }
}

final class ComputerUseIPCXPCTransport: @unchecked Sendable {
    private static let shared = ComputerUseIPCXPCTransport()
    private let queue = AsyncSerialQueue()
    // These fields are accessed only by the serialized bootstrap operation.
    private var processIdentifier: pid_t = 0
    private var cachedConnection: ClientConnection?

    init() {}

    // Must match ComputerUseXPCBootstrap.eventClass in the service ("AxCu").
    private static let bootstrapEventClass: AEEventClass = 0x41784375

    // No-reply bootstrap, with no client-type or telemetry parameter.
    private static func sendBootstrap(pid: pid_t, port: mach_port_t) throws {
        let event = NSAppleEventDescriptor(eventClass: bootstrapEventClass, eventID: 0x5870634e,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: "AcuaComputerUseIPC-5"), forKeyword: 0x436c566e)
        var port = port
        let bytes = withUnsafeBytes(of: &port) { Data($0) }
        guard let descriptor = NSAppleEventDescriptor(descriptorType: 0x706f7274, data: bytes) else {
            throw ClientTransportFailure.couldNotEncodeBootstrapPort
        }
        event.setAttribute(descriptor, forKeyword: 0x72657070)
        do {
            _ = try event.sendEvent(options: .init(rawValue: 33), timeout: 5)
        } catch {
            let native = error as NSError
            if native.domain == NSOSStatusErrorDomain && native.code == -1712 {
                throw ClientTransportFailure.bootstrapTimedOut
            }
            throw error
        }
    }

    private static func endpoint(pid: pid_t, bootstrap: @Sendable (pid_t, mach_port_t) throws -> Void) async throws -> ClientEndpoint {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let port = try ClientReceivePort()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ClientEndpoint.self) { group in
                defer { port.close(); group.cancelAll() }
                let receivePortName = port.value
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global().async {
                            var error: NSError?
                            if let endpoint = CUAReceiveBootstrap(receivePortName, pid, &error) {
                                continuation.resume(returning: ClientEndpoint(value: endpoint))
                            } else {
                                continuation.resume(throwing: error ?? ClientTransportFailure.couldNotReceiveEndpoint)
                            }
                        }
                    }
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw ClientTransportFailure.bootstrapTimedOut
                }
                try bootstrap(pid, port.value)
                return try await group.next()!
            }
        } onCancel: { port.close() }
    }

    private func connection(pid: pid_t,
                            bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void) async throws -> ClientConnection {
        try await queue.sync { [self] in
            if processIdentifier == pid, let cachedConnection, !cachedConnection.isInvalidated {
                return cachedConnection
            }
            let endpoint = try await Self.endpoint(pid: pid, bootstrap: bootstrap)
            let next = ClientConnection(endpoint: endpoint.value)
            let previous = cachedConnection
            processIdentifier = pid
            cachedConnection = next
            if let previous, previous !== next { previous.invalidate() }
            return next
        }
    }

    static func send(_ request: AgentTurnEndedRequest, pid: pid_t,
                     bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws {
        let _: ComputerUseIPCTurnEndedResponse = try await sendRequest(request, pid: pid, bootstrap: bootstrap)
    }

    static func sendRequest<Request: ComputerUseIPCRequest>(_ request: Request, files: [FileHandle] = [], pid: pid_t,
                                                           bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws -> Request.Response {
        let typeName = String(describing: type(of: request))
        let body = try JSONEncoder().encode(request)
        // The shared transport is created only after encoding succeeds.
        // Its queue worker must inherit the first successful caller's scope.
        let transport = shared
        let metadata = ComputerUseTelemetryContext.snapshot().agentTurnMetadataData()
        return try await transport.performEncodedRequest(Request.Response.self, typeName: typeName, body: body,
            metadata: metadata, files: files, pid: pid, bootstrap: bootstrap)
    }

    func sendRequest(typeName: String, requestData: Data, agentMetadataData: Data? = nil, files: [FileHandle] = [], pid: pid_t,
                     bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws -> Data {
        let connection = try await connection(pid: pid, bootstrap: bootstrap)
        return try await connection.send(type: typeName, body: requestData, metadata: agentMetadataData, files: files)
    }

    func performRequest<Request: ComputerUseIPCRequest>(_ request: Request, files: [FileHandle] = [], pid: pid_t,
                                                       bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws -> Request.Response {
        let typeName = String(describing: type(of: request))
        let body = try JSONEncoder().encode(request)
        let metadata = ComputerUseTelemetryContext.snapshot().agentTurnMetadataData()
        return try await performEncodedRequest(Request.Response.self, typeName: typeName, body: body,
            metadata: metadata, files: files, pid: pid, bootstrap: bootstrap)
    }

    private func performEncodedRequest<Response: Decodable>(_ response: Response.Type, typeName: String, body: Data,
                                                            metadata: Data?, files: [FileHandle], pid: pid_t,
                                                            bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void) async throws -> Response {
        let connection: ClientConnection
        do { connection = try await self.connection(pid: pid, bootstrap: bootstrap) }
        catch { try ClientServiceErrorMapper.rethrow(error as NSError) }
        let data: Data
        do { data = try await connection.send(type: typeName, body: body, metadata: metadata, files: files) }
        catch {
            if error is ClientTransportFailure {
                // This operation is enqueued before rethrowing. A newer
                // cached connection must survive a late failure from an older one.
                queue.async { [self, connection] in
                    guard cachedConnection === connection else { return }
                    processIdentifier = 0
                    cachedConnection = nil
                    connection.invalidate()
                }
            }
            try ClientServiceErrorMapper.rethrow(error as NSError)
        }
        return try JSONDecoder().decode(response, from: data)
    }

    static func foregroundUpdates(pid: pid_t,
                                  bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws -> ClientForegroundStream {
        try await shared.subscribeToForegroundUpdates(pid: pid, bootstrap: bootstrap)
    }

    func subscribeToForegroundUpdates(pid: pid_t,
                                     bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws -> ClientForegroundStream {
        try await connection(pid: pid, bootstrap: bootstrap).foregroundUpdates()
    }

    func sendTurnEnded(_ request: AgentTurnEndedRequest, pid: pid_t,
                       bootstrap: @escaping @Sendable (pid_t, mach_port_t) throws -> Void = sendBootstrap) async throws {
        let _: ComputerUseIPCTurnEndedResponse = try await performRequest(request, pid: pid, bootstrap: bootstrap)
    }
}
