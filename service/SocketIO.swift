import Foundation
import Darwin

enum SocketIOError: Error { case timedOut, disconnected, system(Int32) }

/// The optional native socket is resolved through the application group,
/// after a nonempty trimmed environment override. Explicit CLI socket paths
/// remain available for the standalone client and test workflows.
enum ServiceSocketLocation {
    static func resolve(arguments: [String], override: String?, container: () -> URL?) -> URL? {
        if let explicit = arguments.dropFirst().first(where: { !$0.hasPrefix("-psn_") }) {
            return URL(fileURLWithPath: explicit)
        }
        if let configured = override?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return container()?.appendingPathComponent("IPC", isDirectory: true)
            .appendingPathComponent("computeruse.sock", isDirectory: false)
    }
}

@_silgen_name("pthread_fchdir_np")
private func socketThreadDirectory(_ fd: Int32) -> Int32

enum ServiceSocketListenerError: Error {
    case unsafeDirectory, unsafeNode, wrongOwner, alreadyRunning, nodeChanged, pathTooLong
    case lockFailed(Int32), bindFailed(Int32)
}

enum ServiceSocketStartupPolicy {
    // Startup retries only native lock failures, an existing live socket,
    // or EADDRINUSE specifically from bind. Other system failures are terminal
    // for the optional Unix listener, not for the application/XPC service.
    static func canRetry(_ error: Error) -> Bool {
        guard let error = error as? ServiceSocketListenerError else { return false }
        switch error {
        case .lockFailed, .alreadyRunning: return true
        case .bindFailed(let code): return code == EADDRINUSE
        default: return false
        }
    }

    // Retry delay: min(5000, 100 << min(attempt, 6)) ms. No retry limit.
    static func delayMilliseconds(attempt: Int) -> Int {
        guard attempt >= 0 else { return 0 }
        return min(5_000, 100 << min(attempt, 6))
    }
}

/// Native listener preparation: parent directory, exclusive lock, stale
/// socket removal and long-path handling.
final class ServiceSocketListener {
    let fd: Int32
    private let resourceLock = NSLock()
    private var listenerClosed = false
    private let path: String
    private var lockFD: Int32 = -1
    private var boundIdentity: (dev_t, ino_t)?

    static func openWithRecovery(path: String,
        shouldContinue: () -> Bool = { !Thread.current.isCancelled },
        wait: (TimeInterval) -> Void = {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(Int(($0 * 1_000).rounded())))
        },
        onError: (Error) -> Void) -> ServiceSocketListener? {
        var attempt = 0
        while shouldContinue() {
            do { return try ServiceSocketListener(path: path) }
            catch {
                onError(error)
                guard ServiceSocketStartupPolicy.canRetry(error) else { return nil }
                wait(Double(ServiceSocketStartupPolicy.delayMilliseconds(attempt: attempt)) / 1_000)
                // Once capped, further attempts have the same delay.
                attempt = min(attempt + 1, 6)
            }
        }
        return nil
    }

    init(path: String, backlog: Int32 = 128) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketIOError.system(errno) }
        var acquiredLock: Int32 = -1
        do {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(parent, &info) == 0 else { throw SocketIOError.system(errno) }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
                throw ServiceSocketListenerError.unsafeDirectory
            }
            guard info.st_uid == geteuid() else { throw ServiceSocketListenerError.wrongOwner }
            acquiredLock = open(path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard acquiredLock >= 0 else { throw SocketIOError.system(errno) }
            guard fstat(acquiredLock, &info) == 0 else { throw SocketIOError.system(errno) }
            guard info.st_uid == geteuid() else { throw ServiceSocketListenerError.wrongOwner }
            guard fchmod(acquiredLock, 0o600) == 0 else { throw SocketIOError.system(errno) }
            guard flock(acquiredLock, LOCK_EX | LOCK_NB) == 0 else { throw ServiceSocketListenerError.lockFailed(errno) }
            try SocketIO.prepareDescriptor(fd)
            if let previous = try Self.node(path) {
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw SocketIOError.system(errno) }
                defer { close(probe) }
                try SocketIO.prepareDescriptor(probe)
                let inactive = try Self.withAddress(path) { address, length in
                    if connect(probe, address, length) == 0 { return false }
                    let code = errno
                    if code == ECONNREFUSED || code == ENOENT { return true }
                    if code == EINPROGRESS || code == EAGAIN || code == EALREADY || code == EISCONN { return false }
                    throw SocketIOError.system(code)
                }
                guard inactive else { throw ServiceSocketListenerError.alreadyRunning }
                guard let current = try Self.node(path), Self.same(previous, current) else {
                    throw ServiceSocketListenerError.nodeChanged
                }
                guard unlink(path) == 0 else { throw SocketIOError.system(errno) }
            }
            try Self.withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else { throw ServiceSocketListenerError.bindFailed(errno) }
            }
            guard let bound = try Self.node(path) else { throw ServiceSocketListenerError.nodeChanged }
            boundIdentity = (bound.st_dev, bound.st_ino)
            guard chmod(path, 0o600) == 0, listen(fd, backlog) == 0 else { throw SocketIOError.system(errno) }
        } catch {
            if let identity = boundIdentity { Self.remove(path, identity: identity) }
            close(fd)
            if acquiredLock >= 0 { close(acquiredLock) }
            throw error
        }
        lockFD = acquiredLock
    }

    // Close and unlink the listener before cancelling clients,
    // then releases the process lock after their shutdown requests.
    func stopAccepting() {
        resourceLock.lock(); defer { resourceLock.unlock() }
        if !listenerClosed { listenerClosed = true; close(fd) }
        if let identity = boundIdentity {
            boundIdentity = nil
            Self.remove(path, identity: identity)
        }
    }

    func releaseLock() {
        resourceLock.lock(); defer { resourceLock.unlock() }
        if lockFD >= 0 {
            let descriptor = lockFD; lockFD = -1
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    deinit {
        stopAccepting()
        releaseLock()
    }

    private static func node(_ path: String) throws -> stat? {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw SocketIOError.system(errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw ServiceSocketListenerError.unsafeNode }
        guard info.st_uid == geteuid() else { throw ServiceSocketListenerError.wrongOwner }
        return info
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func remove(_ path: String, identity: (dev_t, ino_t)) {
        if let current = try? node(path), current.st_dev == identity.0, current.st_ino == identity.1 { unlink(path) }
    }

    private static func withAddress<Value>(_ path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Value) throws -> Value {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let full = Array(path.utf8)
        var directory: Int32 = -1
        let bytes: [UInt8]
        if full.count < MemoryLayout.size(ofValue: address.sun_path) {
            bytes = full
        } else {
            let url = URL(fileURLWithPath: path)
            bytes = Array(url.lastPathComponent.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw ServiceSocketListenerError.pathTooLong
            }
            directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { throw SocketIOError.system(errno) }
            guard socketThreadDirectory(directory) == 0 else {
                let code = errno; close(directory); throw SocketIOError.system(code)
            }
        }
        defer {
            if directory >= 0 { _ = socketThreadDirectory(-1); close(directory) }
        }
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
                for (i, byte) in bytes.enumerated() { buffer[i] = byte }
                buffer[bytes.count] = 0
            }
        }
        let result = try withUnsafePointer(to: &address) { raw in
            try raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if directory >= 0 {
            guard socketThreadDirectory(-1) == 0 else { throw SocketIOError.system(errno) }
            close(directory)
            directory = -1
        }
        return result
    }
}

// The 30-second timeout applies separately to each complete incoming and
// outgoing frame.
final class SocketIO: @unchecked Sendable {
    // One Darwin control message carries at most 254 rights;
    // the kernel rejects 255 before delivery. Extra rights on later fragments
    // do not invalidate the byte frame. Retain only this bounded routing set.
    static let maxFrameFileCount = 254
    let fd: Int32
    let timeout: Duration
    private var ownsDescriptor = false
    private let stateLock = NSLock()
    private var cancelled = false
    private var closed = false
    private let clock = ContinuousClock()

    init(fd: Int32, timeout: Duration = .seconds(30), ownsDescriptor: Bool = false) throws {
        self.fd = fd
        self.timeout = timeout
        try Self.prepareDescriptor(fd)
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketIOError.system(errno)
        }
        self.ownsDescriptor = ownsDescriptor
    }

    var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled || closed
    }

    // Request shutdown without closing/reusing the descriptor.
    // The serving operation owns the final close.
    func cancel() {
        stateLock.lock(); defer { stateLock.unlock() }
        cancelled = true
        if !closed { _ = shutdown(fd, SHUT_RDWR) }
    }

    func closeOwnedDescriptor() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true
        if ownsDescriptor { close(fd) }
    }

    deinit { closeOwnedDescriptor() }

    // Configures both the listener and accepted sockets before use.
    static func prepareDescriptor(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketIOError.system(errno)
        }
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw SocketIOError.system(errno)
        }
    }

    func deadline() -> ContinuousClock.Instant { clock.now.advanced(by: timeout) }

    private func wait(for events: Int16, until deadline: ContinuousClock.Instant) throws {
        while true {
            guard !isCancelled else { throw CancellationError() }
            guard clock.now < deadline else { throw SocketIOError.timedOut }
            let remaining = clock.now.duration(to: deadline).components
            let milliseconds = Double(remaining.seconds) * 1_000 + Double(remaining.attoseconds) / 1e15
            // Recheck ContinuousClock regularly, including after machine sleep.
            let delay = Int32(max(1, min(50, ceil(milliseconds))))
            var status = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&status, 1, delay)
            guard !isCancelled else { throw CancellationError() }
            if result < 0 {
                if errno == EINTR { continue }
                throw SocketIOError.system(errno)
            }
            guard clock.now < deadline else { throw SocketIOError.timedOut }
            if status.revents & Int16(POLLNVAL) != 0 { throw SocketIOError.disconnected }
            // Drain final readable bytes even if EOF accompanies readiness.
            if status.revents & events != 0 { return }
            if status.revents & Int16(POLLHUP | POLLERR) != 0 { throw SocketIOError.disconnected }
        }
    }

    // nil is clean EOF before this read; partial EOF is always a failure.
    func readExactly(_ count: Int, until deadline: ContinuousClock.Instant) throws -> Data? {
        var files = [FileHandle]()
        let result = try readExactly(count, until: deadline, files: &files)
        guard files.isEmpty else { throw SocketIOError.system(EPROTO) }
        return result
    }

    func readExactly(_ count: Int, until deadline: ContinuousClock.Instant, files: inout [FileHandle]) throws -> Data? {
        precondition(count >= 0)
        if count == 0 { return Data() }
        var data = Data(count: count)
        let complete = try data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < count {
                try wait(for: Int16(POLLIN), until: deadline)
                let n = try receive(raw.baseAddress!.advanced(by: offset), count: min(count - offset, 65_536), files: &files)
                if n == 0 {
                    if offset == 0 { return false }
                    throw SocketIOError.disconnected
                }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw SocketIOError.system(errno)
                }
                offset += n
            }
            return true
        }
        return complete ? data : nil
    }

    private func receive(_ buffer: UnsafeMutableRawPointer, count: Int, files: inout [FileHandle]) throws -> Int {
        // Darwin aligns ancillary headers and payloads to four bytes.
        let headerSize = MemoryLayout<cmsghdr>.size
        let controlSize = headerSize + Self.maxFrameFileCount * MemoryLayout<Int32>.size
        return try withUnsafeTemporaryAllocation(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment) { control in
            var payload = iovec(iov_base: buffer, iov_len: count)
            var message = msghdr()
            message.msg_control = control.baseAddress
            message.msg_controllen = socklen_t(controlSize)
            let received = withUnsafeMutablePointer(to: &payload) { pointer in
                message.msg_iov = pointer
                message.msg_iovlen = 1
                return recvmsg(fd, &message, 0)
            }
            guard received >= 0 else { return received }

            let length = min(Int(message.msg_controllen), controlSize)
            var offset = 0
            var invalid = message.msg_flags & MSG_CTRUNC != 0
            while offset + headerSize <= length {
                let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                let size = Int(header.cmsg_len)
                guard size >= headerSize, size <= length - offset else {
                    invalid = true
                    break
                }
                if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                    let body = offset + headerSize
                    let descriptorSize = MemoryLayout<Int32>.size
                    if (size - headerSize) % descriptorSize != 0 { invalid = true }
                    for index in 0..<(size - headerSize) / descriptorSize {
                        let descriptor = control.loadUnaligned(fromByteOffset: body + index * descriptorSize, as: Int32.self)
                        if fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0 {
                            close(descriptor)
                            invalid = true
                        } else if files.count >= Self.maxFrameFileCount {
                            close(descriptor)
                        } else {
                            files.append(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
                        }
                    }
                } else {
                    invalid = true
                }
                offset += (size + 3) & ~3
            }
            guard !invalid else { throw SocketIOError.system(EPROTO) }
            return received
        }
    }

    func writeAll(_ data: Data) throws {
        let end = deadline()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(for: Int16(POLLOUT), until: end)
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), min(raw.count - offset, 65_536))
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw SocketIOError.system(errno)
                }
                guard n > 0 else { throw SocketIOError.disconnected }
                offset += n
            }
        }
    }
}

// Transport lifecycle. A generation prevents an
// old readiness callback or retry from publishing state after stop/restart.
final class ServiceSocketTransport: @unchecked Sendable {
    typealias ConnectionBody = @Sendable () -> Void
    private struct Client {
        let io: SocketIO
        var task: Task<Void, Never>?
    }
    private let condition = NSCondition()
    private let queue: DispatchQueue
    private let queueIdentity = DispatchSpecificKey<Bool>()
    private let path: String
    private let makeConnection: (SocketIO) -> ConnectionBody?
    private let onError: (Error) -> Void
    private let onListening: () -> Void
    private var active = false
    private var stopping = false
    private var generation: UInt64 = 0
    private var nextClient: UInt64 = 0
    private var listener: ServiceSocketListener?
    private var source: DispatchSourceRead?
    private var retry: DispatchWorkItem?
    private var retryAttempt = 0
    private var clients: [UInt64: Client] = [:]

    init(path: String, onError: @escaping (Error) -> Void, onListening: @escaping () -> Void = {},
         makeConnection: @escaping (SocketIO) -> ConnectionBody?) {
        self.path = path
        self.queue = DispatchQueue(label: "acua.ipc.server", qos: .userInitiated)
        self.onError = onError
        self.onListening = onListening; self.makeConnection = makeConnection
        queue.setSpecific(key: queueIdentity, value: true)
    }

    var activeConnectionCount: Int {
        condition.lock(); defer { condition.unlock() }; return clients.count
    }

    func start() {
        if DispatchQueue.getSpecific(key: queueIdentity) == true { startOnQueue() }
        else { queue.sync { startOnQueue() } }
    }

    private func startOnQueue() {
        condition.lock()
        guard listener == nil else { condition.unlock(); return }
        if !active {
            active = true
            // A terminal attempt can leave an already scheduled retry. Keep
            // its generation until it fires, as the native state does.
            if retry == nil { generation &+= 1 }
        }
        let token = generation
        condition.unlock()
        open(generation: token)
    }

    func waitUntilStopped() {
        condition.lock(); defer { condition.unlock() }
        while active || stopping { condition.wait() }
    }

    func stop() {
        // Stop runs inline on its queue, synchronously otherwise.
        if DispatchQueue.getSpecific(key: queueIdentity) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        condition.lock()
        guard active || listener != nil || retry != nil || !clients.isEmpty else {
            condition.unlock(); return
        }
        active = false; stopping = true; generation &+= 1
        let pending = retry, listening = listener, readiness = source
        let connections = Array(clients.values)
        retry = nil; source = nil; listener = nil; clients.removeAll()
        condition.unlock()
        pending?.cancel()
        readiness?.cancel()
        listening?.stopAccepting()
        for client in connections {
            client.task?.cancel()
            client.io.cancel()
        }
        listening?.releaseLock()
        condition.lock()
        stopping = false; condition.broadcast(); condition.unlock()
    }

    deinit { stop() }

    private func retryFired(generation token: UInt64) {
        condition.lock()
        guard generation == token else { condition.unlock(); return }
        retry = nil
        let shouldOpen = active && listener == nil
        condition.unlock()
        if shouldOpen { open(generation: token) }
    }

    private func open(generation token: UInt64) {
        condition.lock()
        let current = active && generation == token && listener == nil
        condition.unlock()
        guard current else { return }
        let candidate: ServiceSocketListener
        do { candidate = try ServiceSocketListener(path: path) }
        catch {
            onError(error)
            condition.lock()
            guard active && generation == token else { condition.unlock(); return }
            if ServiceSocketStartupPolicy.canRetry(error) {
                guard retry == nil else { condition.unlock(); return }
                // Increment the stored attempt for each scheduled
                // retry. Stop preserves it; successful publication resets it.
                let delay = ServiceSocketStartupPolicy.delayMilliseconds(attempt: retryAttempt)
                retryAttempt += 1
                let item = DispatchWorkItem { [weak self] in
                    self?.retryFired(generation: token)
                }
                retry = item
                condition.unlock()
                queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
            } else {
                active = false; condition.broadcast(); condition.unlock()
            }
            return
        }
        let readiness = DispatchSource.makeReadSource(fileDescriptor: candidate.fd, queue: queue)
        readiness.setEventHandler { [weak self] in self?.acceptAvailable(candidate, generation: token) }
        condition.lock()
        guard active && generation == token else {
            condition.unlock()
            readiness.cancel(); readiness.activate()
            candidate.stopAccepting(); candidate.releaseLock()
            return
        }
        listener = candidate; source = readiness; retryAttempt = 0
        // Publishing and activation are atomic relative to stop(). A cancelled
        // unactivated DispatchSource must still be activated before release.
        readiness.activate()
        condition.unlock()
        onListening()
    }

    private func acceptAvailable(_ listening: ServiceSocketListener, generation token: UInt64) {
        while true {
            condition.lock()
            guard active && generation == token && listener === listening else {
                condition.unlock(); return
            }
            let descriptor = accept(listening.fd, nil, nil)
            let code = errno
            let admitted = descriptor >= 0 && clients.count < 128
            condition.unlock()
            if descriptor < 0 {
                // Retry EINTR, return at EAGAIN, and log other
                // accept errors without terminating the application or XPC.
                if code == EINTR { continue }
                if code != EAGAIN && code != EWOULDBLOCK { onError(SocketIOError.system(code)) }
                return
            }
            guard admitted else { close(descriptor); continue }
            let io: SocketIO
            do { io = try SocketIO(fd: descriptor, ownsDescriptor: true) }
            catch { close(descriptor); onError(error); continue }
            guard let body = makeConnection(io) else { io.closeOwnedDescriptor(); continue }
            condition.lock()
            guard active && generation == token && listener === listening else {
                condition.unlock(); io.closeOwnedDescriptor(); return
            }
            nextClient &+= 1
            let id = nextClient
            clients[id] = Client(io: io, task: nil)
            condition.unlock()
            let task = Task.detached { [weak self] in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        // Keep blocking socket I/O off Swift's cooperative pool;
                        // the owning Task carries cancellation through shutdown.
                        Thread.detachNewThread {
                            if !io.isCancelled { body() }
                            io.closeOwnedDescriptor()
                            self?.finished(id)
                            done.resume()
                        }
                    }
                } onCancel: { io.cancel() }
            }
            condition.lock()
            if clients[id] != nil && active && generation == token {
                clients[id]?.task = task
                condition.unlock()
            } else {
                condition.unlock(); task.cancel()
            }
        }
    }

    private func finished(_ id: UInt64) {
        condition.lock(); clients.removeValue(forKey: id); condition.unlock()
    }
}

// Accepted sockets are rejected when the active count is >127.
final class ConnectionSlots {
    private let lock = NSLock()
    private var count = 0
    let limit: Int
    init(limit: Int = 128) { self.limit = limit }
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }
    func release() { lock.lock(); defer { lock.unlock() }; precondition(count > 0); count -= 1 }
}
