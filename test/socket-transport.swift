import Foundation
import Darwin

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
    var current: Value { lock.lock(); defer { lock.unlock() }; return value }
}

@main enum SocketTransportChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/cua-transport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var cases = [String]()
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name); cases.append(name); print("PASS \(name)")
        }
        func eventually(_ predicate: () -> Bool) -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !predicate() {
                if ContinuousClock.now >= deadline { return false }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return true
        }
        func connect(_ path: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); precondition(fd >= 0)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            precondition(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes + [0]) }
            let result = withUnsafePointer(to: &address) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(result == 0, "connect \(errno)"); return fd
        }
        func echo(_ fd: Int32) -> Bool {
            var byte: UInt8 = 71
            return Darwin.write(fd, &byte, 1) == 1 && Darwin.read(fd, &byte, 1) == 1 && byte == 71
        }
        func eof(_ fd: Int32) -> Bool { var byte: UInt8 = 0; return Darwin.read(fd, &byte, 1) == 0 }
        let errors = Box([String]()), cancelled = Box(0), cancelledWhileOpen = Box(0)
        let listening = DispatchSemaphore(value: 0)
        let path = root.appendingPathComponent("primary.sock").path
        let transport = ServiceSocketTransport(path: path, onError: { error in errors.update { $0.append(String(reflecting: error)) } },
            onListening: { listening.signal() }, makeConnection: { io in
                return {
                    do {
                        while let byte = try io.readExactly(1, until: io.deadline()) { try io.writeAll(byte) }
                    } catch is CancellationError {
                        cancelled.update { $0 += 1 }
                        if fcntl(io.fd, F_GETFD) >= 0 { cancelledWhileOpen.update { $0 += 1 } }
                    } catch {}
                }
            })
        transport.start(); transport.start()
        check("duplicate start publishes one listener", listening.wait(timeout: .now() + 5) == .success && listening.wait(timeout: .now() + 0.02) == .timedOut)
        let peer = connect(path)
        check("native read source accepts and serves a client", echo(peer) && transport.activeConnectionCount == 1)
        let began = ContinuousClock.now
        transport.stop(); transport.waitUntilStopped()
        check("stop clears the connection table and unlinks its socket", transport.activeConnectionCount == 0 && !FileManager.default.fileExists(atPath: path))
        check("stop interrupts a blocked reader without its 30 second deadline", eof(peer) && began.duration(to: .now) < .seconds(2))
        check("Task cancellation reaches the serving operation", eventually { cancelled.current == 1 })
        check("shutdown preserves the descriptor until serving cleanup", cancelledWhileOpen.current == 1)
        close(peer)
        var replacement: ServiceSocketListener? = try ServiceSocketListener(path: path)
        check("stop releases the process lock for another listener", replacement != nil)
        replacement = nil
        transport.stop()
        transport.start()
        check("the same owner can restart after stop", listening.wait(timeout: .now() + 5) == .success)
        let restarted = connect(path)
        check("a stale source does not close the restarted connection", echo(restarted))
        transport.stop(); close(restarted)
        check("normal lifecycle does not report accept or bind failures", errors.current.isEmpty)

        let admissionReady = DispatchSemaphore(value: 0)
        let admissionPath = root.appendingPathComponent("admission.sock").path
        let admission = ServiceSocketTransport(path: admissionPath, onError: { _ in }, onListening: { admissionReady.signal() }, makeConnection: { io in
            return { _ = try? io.readExactly(1, until: io.deadline()) }
        })
        admission.start(); precondition(admissionReady.wait(timeout: .now() + 5) == .success)
        let peers = (0..<128).map { _ in connect(admissionPath) }
        check("the production owner tracks 128 active connections", eventually { admission.activeConnectionCount == 128 })
        let overflow = connect(admissionPath)
        check("the 129th accepted client is closed", eof(overflow)); close(overflow)
        admission.stop()
        check("stop shuts down all 128 admitted clients", peers.allSatisfy(eof))
        peers.forEach { close($0) }
        check("bulk stop leaves no listener or registered connection", admission.activeConnectionCount == 0 && !FileManager.default.fileExists(atPath: admissionPath))

        let retryPath = root.appendingPathComponent("retry.sock").path
        var blocker: ServiceSocketListener? = try ServiceSocketListener(path: retryPath)
        let retryError = DispatchSemaphore(value: 0)
        let retryOwner = ServiceSocketTransport(path: retryPath, onError: { _ in retryError.signal() }, makeConnection: { _ in nil })
        retryOwner.start()
        check("a locked listener schedules startup recovery", retryError.wait(timeout: .now() + 5) == .success)
        retryOwner.stop(); blocker = nil
        Thread.sleep(forTimeInterval: 0.25)
        check("stop cancels a pending retry before it can bind", !FileManager.default.fileExists(atPath: retryPath))
        withExtendedLifetime(blocker) {}

        let unsafe = root.appendingPathComponent("regular-file.sock")
        try Data("owned".utf8).write(to: unsafe)
        let terminalError = DispatchSemaphore(value: 0)
        let terminalOwner = ServiceSocketTransport(path: unsafe.path, onError: { _ in terminalError.signal() }, makeConnection: { _ in nil })
        terminalOwner.start()
        check("a terminal startup failure reports the error", terminalError.wait(timeout: .now() + 5) == .success)
        terminalOwner.waitUntilStopped()
        check("a terminal startup failure preserves the existing file", try Data(contentsOf: unsafe) == Data("owned".utf8))

        let rejectedPath = root.appendingPathComponent("rejected.sock").path
        let factoryEntered = DispatchSemaphore(value: 0), factoryRelease = DispatchSemaphore(value: 0)
        let rejection = ServiceSocketTransport(path: rejectedPath, onError: { _ in }, makeConnection: { io in
            factoryEntered.signal()
            precondition(factoryRelease.wait(timeout: .now() + 5) == .success)
            return { _ = try? io.readExactly(1, until: io.deadline()) }
        })
        rejection.start()
        precondition(eventually { FileManager.default.fileExists(atPath: rejectedPath) })
        let rejected = connect(rejectedPath)
        precondition(factoryEntered.wait(timeout: .now() + 5) == .success)
        let stopped = DispatchSemaphore(value: 0), stopping = DispatchSemaphore(value: 0)
        Thread.detachNewThread { stopping.signal(); rejection.stop(); stopped.signal() }
        precondition(stopping.wait(timeout: .now() + 5) == .success)
        check("external stop waits for an in-flight admission on its queue", stopped.wait(timeout: .now() + 0.05) == .timedOut)
        factoryRelease.signal()
        check("queued stop completes after admission returns", stopped.wait(timeout: .now() + 5) == .success)
        check("stop retires the connection admitted ahead of it", eof(rejected) && rejection.activeConnectionCount == 0)
        close(rejected)

        let failedDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        precondition(failedDescriptor >= 0)
        do {
            _ = try SocketIO(fd: failedDescriptor, ownsDescriptor: true)
            preconditionFailure("regular file accepted as socket")
        } catch {}
        check("failed socket preparation leaves ownership with the caller", fcntl(failedDescriptor, F_GETFD) >= 0)
        close(failedDescriptor)

        var sockets = [Int32](repeating: -1, count: 2)
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let retired = try SocketIO(fd: sockets[0], ownsDescriptor: true)
        retired.cancel()
        check("shutdown alone does not close an owned descriptor", fcntl(sockets[0], F_GETFD) >= 0)
        retired.closeOwnedDescriptor()
        let reused = open("/dev/null", O_RDONLY | O_CLOEXEC)
        precondition(reused >= 0)
        if reused != sockets[0] { precondition(dup2(reused, sockets[0]) == sockets[0]) }
        retired.cancel(); retired.closeOwnedDescriptor()
        check("late cancellation and duplicate close preserve a reused fd", fcntl(sockets[0], F_GETFD) >= 0)
        close(sockets[0]); if reused != sockets[0] { close(reused) }; close(sockets[1])

        for index in 0..<30 {
            let stressPath = root.appendingPathComponent("race-\(index).sock").path
            let owner = ServiceSocketTransport(path: stressPath, onError: { _ in }, makeConnection: { _ in nil })
            let group = DispatchGroup()
            for turn in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    if turn % 2 == 0 { owner.start() } else { owner.stop() }
                    group.leave()
                }
            }
            precondition(group.wait(timeout: .now() + 5) == .success)
            owner.stop(); owner.waitUntilStopped()
            check("concurrent start/stop retires all resources \(index)", !FileManager.default.fileExists(atPath: stressPath))
            let next = try ServiceSocketListener(path: stressPath)
            withExtendedLifetime(next) {}
        }
        print("ALL \(cases.count) SOCKET TRANSPORT CHECKS PASSED")
    }
}
