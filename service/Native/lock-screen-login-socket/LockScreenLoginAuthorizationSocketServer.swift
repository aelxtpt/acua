import Foundation
import Darwin

@MainActor protocol LockScreenLoginAuthorizationConsuming: AnyObject {
    func consumePendingLoginAuthorizationAttempt() -> Bool
}
extension LockScreenLoginAuthorizationBroker: LockScreenLoginAuthorizationConsuming {}

/// Attempt-consumption channel. It reads no request body and applies no
/// peer-UID/PID/signature policy of its own.
@MainActor final class LockScreenLoginAuthorizationSocketServer {
    static let defaultSocketDirectoryPath = "/tmp/com.aex.computeruse"
    static let defaultSocketPath = defaultSocketDirectoryPath + "/LockScreenLoginAuthorization.sock"
    let socketPath: String
    private let broker: any LockScreenLoginAuthorizationConsuming
    private let io: LockScreenLoginSocketIO
    private let onShortWrite: (Int) -> Void
    private let onAcceptError: (Int32) -> Void
    private var listenerSource: LockScreenLoginReadSource?
    private(set) var listenerFD: Int32 = 0
    private(set) var isOpen = false
    var hasReadSource: Bool { listenerSource != nil }

    init(socketPath: String = defaultSocketPath,
         loginAuthorizationBrokerFactory: () -> any LockScreenLoginAuthorizationConsuming,
         io: LockScreenLoginSocketIO = .native,
         onShortWrite: @escaping (Int) -> Void = {_ in},onAcceptError: @escaping (Int32) -> Void = {_ in}) {
        self.socketPath = socketPath; broker = loginAuthorizationBrokerFactory()
        self.io = io; self.onShortWrite = onShortWrite; self.onAcceptError = onAcceptError
    }
    func start() throws {
        guard !isOpen else { return }
        let fd = io.socket()
        guard fd >= 0 else { throw LockScreenLoginSocketError.socket(io.error()) }
        do {
            try prepareDirectory()
            let flags = io.getFlags(fd)
            guard flags >= 0,io.setFlags(fd,flags | O_NONBLOCK) == 0 else { throw LockScreenLoginSocketError.fcntl(io.error()) }
            io.unlink(socketPath)
            let address = try LockScreenLoginSocketAddress(path:socketPath)
            guard io.bind(fd,address) == 0 else { throw LockScreenLoginSocketError.bind(io.error()) }
            guard io.chmod(socketPath,0o666) == 0 else { throw LockScreenLoginSocketError.chmod(io.error()) }
            guard io.listen(fd,4) == 0 else { throw LockScreenLoginSocketError.listen(io.error()) }
        } catch {
            io.close(fd); io.unlink(socketPath)
            throw error
        }
        listenerFD = fd; isOpen = true
        let source = io.readSource(fd) { [weak self] in self?.acceptReady() }
        source.resume()
        listenerSource = source
    }
    func stop() {
        listenerSource?.cancel(); listenerSource = nil
        if isOpen { io.close(listenerFD); listenerFD = 0; isOpen = false }
        io.unlink(socketPath)
    }
    private func prepareDirectory() throws {
        let path = URL(fileURLWithPath:socketPath).deletingLastPathComponent().path
        if io.mkdir(path,0o755) == 0 { return }
        guard io.error() == EEXIST else { throw LockScreenLoginSocketError.mkdir(io.error()) }
        guard let info = io.lstat(path) else { throw LockScreenLoginSocketError.stat(io.error()) }
        guard info.mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw LockScreenLoginSocketError.directoryIsNotDirectory(path) }
        guard info.owner == io.effectiveUID() else { throw LockScreenLoginSocketError.directoryOwner(path,info.owner) }
    }
    func acceptReady() {
        guard isOpen else { return }
        let listener = listenerFD
        var accepted = io.accept(listener)
        while accepted >= 0 {
            let reply = broker.consumePendingLoginAuthorizationAttempt() ? "ALLOW\n" : "DENY\n"
            let data = Data(reply.utf8)
            let written = io.write(accepted,data)
            if written != data.count { onShortWrite(written) }
            io.close(accepted)
            accepted = io.accept(listener)
        }
        let code = io.error()
        if code != EAGAIN && code != EWOULDBLOCK { onAcceptError(code) }
    }
    // The destructor drops source/broker/path without calling stop. The
    // owning service must explicitly stop this component to close/unlink.
}
