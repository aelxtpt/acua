import Foundation
import XPC

typealias ComputerUseXPCFileArray = NSObject & OS_xpc_object

@objc(SAIComputerUseForegroundObserver)
protocol ComputerUseXPCForegroundObserver {
    @objc(receiveForegroundContext:)
    func receiveForegroundContext(_ data: Data)
}

@objc(SAIComputerUseIPCXPCProtocol)
protocol ComputerUseXPCProtocol {
    @objc(sendRequestWithTypeName:requestData:agentMetadataData:fileDescriptors:withReply:)
    func sendRequest(typeName: String, requestData: Data?, agentMetadataData: Data?, fileDescriptors: ComputerUseXPCFileArray,
                     reply: @escaping (Data?, NSError?) -> Void)

    @objc(subscribeToForegroundContextWithID:observer:withReply:)
    func subscribeToForegroundContext(id: NSUUID, observer: ComputerUseXPCForegroundObserver, reply: @escaping (NSError?) -> Void)

    @objc(unsubscribeFromForegroundContextWithID:)
    func unsubscribeFromForegroundContext(id: NSUUID)
}

struct ComputerUseXPCForegroundContext: Codable, Equatable, Sendable {
    var processIdentifier: Int32
    var windowID: UInt32?
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String?
}

struct ComputerUseXPCForegroundUpdate: Codable, Equatable, Sendable {
    var observedAt: Date
    var context: ComputerUseXPCForegroundContext?
}

@MainActor
final class ComputerUseForegroundUpdates {
    typealias Update = ComputerUseXPCForegroundUpdate
    private let start: (ComputerUseForegroundUpdates) -> Void
    private let stop: () -> Void
    private var subscribers = [UUID: AsyncStream<Update>.Continuation]()
    private var latest: Update?
    var hasSubscribers: Bool { !subscribers.isEmpty }

    init(start: @escaping (ComputerUseForegroundUpdates) -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
    }

    func subscribe() -> AsyncStream<Update> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.remove(id) }
        }
        subscribers[id] = continuation
        if subscribers.count == 1 {
            start(self)
        } else if let latest {
            continuation.yield(latest)
        }
        return stream
    }

    func publish(_ context: ComputerUseXPCForegroundContext?, at date: Date) {
        guard !subscribers.isEmpty, latest == nil || latest?.context != context else { return }
        let update = Update(observedAt: date, context: context)
        latest = update
        for subscriber in subscribers.values { subscriber.yield(update) }
    }

    private func remove(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty else { return }
        latest = nil
        stop()
    }
}

enum ComputerUseXPC {
    static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ComputerUseXPCProtocol.self)
        interface.setXPCType(XPC_TYPE_ARRAY,
            for: #selector(ComputerUseXPCProtocol.sendRequest(typeName:requestData:agentMetadataData:fileDescriptors:reply:)),
            argumentIndex: 3, ofReply: false)
        interface.setInterface(NSXPCInterface(with: ComputerUseXPCForegroundObserver.self),
            for: #selector(ComputerUseXPCProtocol.subscribeToForegroundContext(id:observer:reply:)),
            argumentIndex: 1, ofReply: false)
        return interface
    }

    static func error(_ code: CUErrorCode, _ message: String) -> NSError {
        NSError(domain: "ComputerUseIPCXPC", code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func requestError(_ failure: Error) -> NSError {
        if let service = failure as? ServiceError {
            return error(service.code, service.message)
        }
        return error(.unknownError, String(describing: failure))
    }

    static func requestBody(_ request: Data?) throws -> Any {
        try decodeJSONDocument(request ?? Data())
    }

    static func files(_ descriptors: ComputerUseXPCFileArray) throws -> [FileHandle] {
        var files = [FileHandle]()
        guard xpc_get_type(descriptors) == XPC_TYPE_ARRAY, xpc_array_apply(descriptors, { _, item in
            guard xpc_get_type(item) == XPC_TYPE_FD else { return false }
            let fd = xpc_fd_dup(item)
            guard fd >= 0 else { return false }
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); return false }
            files.append(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
            return true
        }) else {
            throw error(.messagesInvalidRequest, "attachment file descriptors were invalid")
        }
        return files
    }
}

final class ComputerUseXPCSession: NSObject, NSXPCListenerDelegate, ComputerUseXPCProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (String, Data?, Data?, [FileHandle], @escaping () -> Bool) throws -> Data
    private let listener = NSXPCListener.anonymous()
    private let peerPID: pid_t
    private let foregroundOnly: Bool
    private let handle: Handler
    private let foreground: ComputerUseForegroundUpdates
    private let finished: @Sendable () -> Void
    private let lock = NSLock()
    private var connections = [ObjectIdentifier: NSXPCConnection]()
    private var invalidated = false
    private var stopped = false
    private var subscriptions = [UUID: Task<Void, Never>]()

    init(peerPID: pid_t, peerUID: uid_t, handler: @escaping Handler,
         foreground: ComputerUseForegroundUpdates,
         foregroundOnly: Bool = false,
         finished: @escaping @Sendable () -> Void = {}) {
        self.peerPID = peerPID
        self.foregroundOnly = foregroundOnly
        self.handle = handler
        self.foreground = foreground
        self.finished = finished
        super.init()
        listener.delegate = self
        listener.activate()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    var isInvalidated: Bool { lock.withLock { invalidated } }
    private var isStopped: Bool { lock.withLock { stopped } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection candidate: NSXPCConnection) -> Bool {
        guard XPCSessionAdmission.permits(foregroundOnly: foregroundOnly, senderPID: peerPID,
                                         candidatePID: candidate.processIdentifier) else { return false }
        return lock.withLock {
            let id = ObjectIdentifier(candidate)
            guard !invalidated, connections[id] == nil else { return false }
            candidate.exportedInterface = ComputerUseXPC.interface()
            candidate.exportedObject = self
            candidate.invalidationHandler = { [weak self] in self?.connectionEnded(id) }
            connections[id] = candidate
            candidate.activate()
            return true
        }
    }

    func invalidate() {
        invalidate(onlyIfUnconnected: false)
    }

    func invalidateIfUnconnected() {
        invalidate(onlyIfUnconnected: true)
    }

    private func invalidate(onlyIfUnconnected: Bool) {
        let old: [NSXPCConnection]
        lock.lock()
        guard !stopped, !onlyIfUnconnected || connections.isEmpty else { lock.unlock(); return }
        let notify = !invalidated
        invalidated = true
        stopped = true
        old = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener.invalidate()
        cancelSubscriptionsOnMain()
        old.forEach { $0.invalidate() }
        if notify { finished() }
    }

    private func connectionEnded(_ id: ObjectIdentifier) {
        lock.lock()
        guard connections.removeValue(forKey: id) != nil else { lock.unlock(); return }
        let closesListener = !invalidated
        invalidated = true
        lock.unlock()
        // Closing admission does not cancel an already running handler task.
        // Foundation also invalidates the listener's accepted connections.
        if closesListener {
            listener.invalidate()
            cancelSubscriptionsOnMain()
        }
        finished()
    }

    private func cancelSubscriptionsOnMain() {
        DispatchQueue.main.async { [self] in
            lock.withLock {
                subscriptions.values.forEach { $0.cancel() }
                subscriptions.removeAll()
            }
        }
    }

    func sendRequest(typeName: String, requestData: Data?, agentMetadataData: Data?, fileDescriptors: ComputerUseXPCFileArray,
                     reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let files = try ComputerUseXPC.files(fileDescriptors)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, !self.isStopped else {
                    reply(nil, ComputerUseXPC.error(.unknownError, "Computer Use XPC session is unavailable."))
                    return
                }
                do {
                    guard !self.foregroundOnly else {
                        throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
                    }
                    reply(try self.handle(typeName, requestData, agentMetadataData, files, { self.isStopped }), nil)
                } catch {
                    reply(nil, ComputerUseXPC.requestError(error))
                }
            }
        } catch {
            reply(nil, error as NSError)
        }
    }

    func subscribeToForegroundContext(id: NSUUID, observer: ComputerUseXPCForegroundObserver, reply: @escaping (NSError?) -> Void) {
        let key = id as UUID
        DispatchQueue.main.async { [self] in
            let error: NSError? = lock.withLock {
                guard !stopped else { return ComputerUseXPC.error(.unknownError, "Computer Use XPC session is unavailable.") }
                guard subscriptions[key] != nil || subscriptions.count < 16 else {
                    return ComputerUseXPC.error(.unknownError, "Foreground subscription limit reached (16 per connection).")
                }
                subscriptions[key]?.cancel()
                subscriptions[key] = Task { @MainActor [foreground] in
                    guard !Task.isCancelled else { return }
                    let encoder = JSONEncoder()
                    for await update in foreground.subscribe() {
                        if !Task.isCancelled, let data = try? encoder.encode(update) {
                            observer.receiveForegroundContext(data)
                        }
                    }
                }
                return nil
            }
            reply(error)
        }
    }

    func unsubscribeFromForegroundContext(id: NSUUID) {
        let key = id as UUID
        DispatchQueue.main.async { [self] in
            lock.withLock { subscriptions.removeValue(forKey: key)?.cancel() }
        }
    }
}
