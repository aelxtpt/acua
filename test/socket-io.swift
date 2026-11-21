import Foundation
import Darwin

private final class ResultBox<Value> {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
}

@main enum SocketIOTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name); passed += 1; print("PASS \(name)")
        }
        var containerCalls = 0
        func location(_ arguments: [String] = ["service"], _ override: String? = nil, _ root: URL? = nil) -> String? {
            ServiceSocketLocation.resolve(arguments: arguments, override: override, container: {
                containerCalls += 1; return root
            })?.path(percentEncoded: false)
        }
        check("missing group container leaves the Unix endpoint disabled", location() == nil)
        let containerRoot = URL(fileURLWithPath: "/private/tmp/Owned Política %", isDirectory: true)
        check("native default comes from the group container", location(["service"], nil, containerRoot) ==
              "/private/tmp/Owned Política %/IPC/computeruse.sock")
        check("blank environment falls back to the container", location(["service"], " \t\n", containerRoot) ==
              "/private/tmp/Owned Política %/IPC/computeruse.sock")
        let calls = containerCalls
        check("environment override trims whitespace without escaping the path",
              location(["service"], " \n/private/tmp/Owned Política %.sock\t") == "/private/tmp/Owned Política %.sock")
        check("explicit standalone path retains precedence over environment",
              location(["service", "/private/tmp/explicit.sock"], "/private/tmp/environment.sock") == "/private/tmp/explicit.sock")
        check("overrides never query a missing container", containerCalls == calls)
        check("legacy LaunchServices token is not a socket path",
              location(["service", "-psn_0_123"], nil, containerRoot) == "/private/tmp/Owned Política %/IPC/computeruse.sock")
        check("LaunchServices token can precede an explicit standalone path",
              location(["service", "-psn_0_123", "/private/tmp/explicit.sock"]) == "/private/tmp/explicit.sock")

        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("cua-endpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("missing/IPC/owned.sock").path
        var endpoint: ServiceSocketListener? = try ServiceSocketListener(path: socketPath)
        var info = stat()
        check("new endpoint retains its open listener descriptor", fcntl(endpoint!.fd, F_GETFD) >= 0)
        check("endpoint creates its missing parent", lstat(URL(fileURLWithPath: socketPath).deletingLastPathComponent().path, &info) == 0)
        check("new socket directory is private", info.st_mode & 0o777 == 0o700)
        check("bound socket is private", lstat(socketPath, &info) == 0 && info.st_mode & 0o777 == 0o600)
        func rejected(_ path: String) -> Bool {
            do { _ = try ServiceSocketListener(path: path); return false } catch { return true }
        }
        check("another endpoint cannot replace a live locked endpoint", rejected(socketPath))
        withExtendedLifetime(endpoint) {}
        endpoint = nil
        check("endpoint teardown removes its own socket", lstat(socketPath, &info) != 0 && errno == ENOENT)
        let lockPath = socketPath + ".lock"
        check("lock file remains private for the next instance", lstat(lockPath, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let original = Data("owned-file".utf8)
        try original.write(to: URL(fileURLWithPath: socketPath))
        check("a regular file at the socket path is rejected", rejected(socketPath))
        check("rejected regular file is preserved", try Data(contentsOf: URL(fileURLWithPath: socketPath)) == original)
        try FileManager.default.removeItem(atPath: socketPath)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
        check("a symlink as the socket parent is rejected", rejected(alias.appendingPathComponent("other.sock").path))
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        for mode: mode_t in [0o702, 0o720, 0o777] {
            precondition(chmod(parent, mode) == 0)
            check("writable shared parent is rejected (\(mode))", rejected(socketPath))
        }
        precondition(chmod(parent, 0o700) == 0)
        try FileManager.default.removeItem(atPath: lockPath)
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: root.appendingPathComponent("lock-target").path)
        check("a symlink lock file is rejected", rejected(socketPath))
        try FileManager.default.removeItem(atPath: lockPath)

        func bindOwned(_ fd: Int32, path: String) {
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8); precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: 104) { buffer in
                    for (i, byte) in bytes.enumerated() { buffer[i] = byte }; buffer[bytes.count] = 0
                }
            }
            precondition(withUnsafePointer(to: &address) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            } == 0)
        }
        let stale = socket(AF_UNIX, SOCK_STREAM, 0); precondition(stale >= 0)
        bindOwned(stale, path: socketPath); close(stale)
        endpoint = try ServiceSocketListener(path: socketPath)
        check("a disconnected owned socket can be replaced", endpoint != nil)
        endpoint = nil
        let active = socket(AF_UNIX, SOCK_STREAM, 0); precondition(active >= 0)
        bindOwned(active, path: socketPath); precondition(listen(active, 2) == 0)
        check("an active endpoint without a lock is preserved", rejected(socketPath))
        close(active); unlink(socketPath)

        let currentDirectory = FileManager.default.currentDirectoryPath
        let longPath = root.appendingPathComponent(String(repeating: "d", count: 90)).appendingPathComponent("IPC/long.sock").path
        endpoint = try ServiceSocketListener(path: longPath)
        check("long absolute paths bind through the parent directory", lstat(longPath, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
        check("long-path bind restores the thread directory", FileManager.default.currentDirectoryPath == currentDirectory)
        withExtendedLifetime(endpoint) {}; endpoint = nil
        check("long-path teardown removes its own socket", lstat(longPath, &info) != 0 && errno == ENOENT)
        let tooLongName = root.appendingPathComponent(String(repeating: "s", count: 104)).path
        check("an overlong socket basename is rejected", rejected(tooLongName))
        check("a failed long-path bind restores the thread directory", FileManager.default.currentDirectoryPath == currentDirectory)
        endpoint = try ServiceSocketListener(path: socketPath)
        precondition(unlink(socketPath) == 0)
        try original.write(to: URL(fileURLWithPath: socketPath))
        withExtendedLifetime(endpoint) {}; endpoint = nil
        check("teardown preserves a file that replaced the bound socket", try Data(contentsOf: URL(fileURLWithPath: socketPath)) == original)
        try FileManager.default.removeItem(atPath: socketPath)
        try FileManager.default.createSymbolicLink(atPath: socketPath, withDestinationPath: root.appendingPathComponent("socket-target").path)
        check("a symlink at the socket path is rejected", rejected(socketPath))
        check("rejected socket symlink is preserved", lstat(socketPath, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        let blockedParent = root.appendingPathComponent("parent-file")
        try original.write(to: blockedParent)
        check("a file in place of the socket parent is rejected", rejected(blockedParent.appendingPathComponent("other.sock").path))
        func pair(_ body: (SocketIO, Int32) throws -> Void) throws {
            var sockets = [Int32](repeating: 0, count: 2)
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
            defer { close(sockets[0]); close(sockets[1]) }
            try body(SocketIO(fd: sockets[0], timeout: .milliseconds(200)), sockets[1])
        }
        func isTimeout(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch SocketIOError.timedOut { return true } catch { return false }
        }
        func sendRights(_ peer: Int32, _ bytes: [UInt8], _ file: Int32, count: Int) {
            let headerSize = MemoryLayout<cmsghdr>.size
            let size = headerSize + count * MemoryLayout<Int32>.size
            withUnsafeTemporaryAllocation(byteCount: size, alignment: MemoryLayout<cmsghdr>.alignment) { control in
                control.storeBytes(of: cmsghdr(cmsg_len: socklen_t(size), cmsg_level: SOL_SOCKET,
                                              cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
                for index in 0..<count {
                    control.storeBytes(of: file, toByteOffset: headerSize + index * 4, as: Int32.self)
                }
                bytes.withUnsafeBytes { raw in
                    var payload = iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress), iov_len: raw.count)
                    var message = msghdr()
                    message.msg_control = control.baseAddress; message.msg_controllen = socklen_t(size)
                    let sent = withUnsafeMutablePointer(to: &payload) { pointer in
                        message.msg_iov = pointer; message.msg_iovlen = 1
                        return sendmsg(peer, &message, 0)
                    }
                    precondition(sent == bytes.count, "send rights: \(errno)")
                }
            }
        }
        let attachment = open("/dev/null", O_RDONLY | O_CLOEXEC)
        precondition(attachment >= 0)
        defer { close(attachment) }
        for count in [1, 65, 254] {
            try pair { io, peer in
                var files = [FileHandle]()
                sendRights(peer, [1, 2, 3, 4], attachment, count: count)
                let bytes = try io.readExactly(4, until: io.deadline(), files: &files)
                check("ancillary transfer preserves bytes and all \(count) files", bytes == Data([1, 2, 3, 4]) && files.count == count)
                let descriptors = files.map(\.fileDescriptor)
                check("all \(count) received files are closed on exec", descriptors.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
                files.removeAll()
                check("releasing \(count) received files closes their duplicates", descriptors.allSatisfy { fcntl($0, F_GETFD) == -1 })
                check("releasing transferred files preserves the sender handle", fcntl(attachment, F_GETFD) >= 0)
            }
        }
        try pair { io, peer in
            var files = [FileHandle]()
            let openCount = { (0..<2048).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
            let baseline = openCount()
            sendRights(peer, [7], attachment, count: 254)
            sendRights(peer, [0, 0, 0, 1, 2, 3, 4, 5, 6, 7], attachment, count: 254)
            let deadline = io.deadline()
            let header = try io.readExactly(4, until: deadline, files: &files)
            let body = try io.readExactly(7, until: deadline, files: &files)
            check("multiple rights messages preserve one fragmented frame", header == Data([7, 0, 0, 0]) && body == Data([1, 2, 3, 4, 5, 6, 7]))
            check("rights retention stays bounded across frame fragments", files.count == 254 && openCount() == baseline + 254)
            files.removeAll()
            check("retained and surplus rights leave no receiver leak", openCount() == baseline)
        }
        try pair { io, peer in
            let payload = Data([1, 2, 3, 4])
            _ = payload.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
            let received = try io.readExactly(4, until: io.deadline())
            check("read returns exact bytes", received == payload)
            check("socket is nonblocking", fcntl(io.fd, F_GETFL) & O_NONBLOCK != 0)
            check("connected sockets are closed on exec", fcntl(io.fd, F_GETFD) & FD_CLOEXEC != 0)
            let empty = try io.readExactly(0, until: io.deadline())
            check("zero-byte body does not wait", empty == Data())
        }
        try pair { io, _ in
            let start = ContinuousClock.now
            check("idle read has a deadline", isTimeout { _ = try io.readExactly(4, until: io.deadline()) })
            let elapsed = start.duration(to: .now)
            check("read timeout is bounded", elapsed >= .milliseconds(170) && elapsed < .seconds(3))
        }
        try pair { io, peer in
            let deadline = io.deadline()
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                var byte: UInt8 = 7
                for _ in 0..<3 { Thread.sleep(forTimeInterval: 0.05); _ = Darwin.write(peer, &byte, 1) }
                done.signal()
            }
            check("partial progress cannot restart the frame deadline", isTimeout { _ = try io.readExactly(4, until: deadline) })
            precondition(done.wait(timeout: .now() + 2) == .success)
        }
        try pair { io, peer in
            var header: UInt32 = 1
            _ = Darwin.write(peer, &header, 4)
            let deadline = io.deadline()
            _ = try io.readExactly(4, until: deadline)
            Thread.sleep(forTimeInterval: 0.12)
            let start = ContinuousClock.now
            check("header and body share the same deadline", isTimeout { _ = try io.readExactly(1, until: deadline) })
            check("body receives only remaining time", start.duration(to: .now) < .milliseconds(180))
        }
        try pair { io, peer in
            _ = shutdown(peer, SHUT_WR)
            let empty = try io.readExactly(4, until: io.deadline())
            check("clean half-close produces EOF", empty == nil)
        }
        try pair { io, peer in
            var byte: UInt8 = 8
            _ = Darwin.write(peer, &byte, 1); _ = shutdown(peer, SHUT_WR)
            do { _ = try io.readExactly(4, until: io.deadline()); preconditionFailure("partial EOF") }
            catch SocketIOError.disconnected { check("partial EOF cannot become a complete frame", true) }
        }
        try pair { io, peer in
            _ = shutdown(peer, SHUT_RDWR)
            do { try io.writeAll(Data([1])); preconditionFailure("peer shutdown") }
            catch { check("disconnected writes fail without SIGPIPE", true) }
        }
        try pair { io, _ in
            var size: Int32 = 4096
            precondition(setsockopt(io.fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0)
            let committed = ResultBox(0), abandoned = ResultBox(0)
            let delivery = ResponseDelivery()
            ResponseDelivery.withCurrent(delivery) {
                _ = ResponseDelivery.reserve(commit: { committed.update { $0 += 1 } },
                                             abandon: { abandoned.update { $0 += 1 } })
            }
            check("client that stops reading cannot block writes forever", isTimeout {
                try io.writeAll(Data(repeating: 42, count: 2_000_000)); delivery.commit()
            })
            delivery.abandon()
            check("failed real socket write abandons publication", committed.value == 0 && abandoned.value == 1)
        }
        try pair { io, peer in
            let received = ResultBox(Data())
            let done = DispatchSemaphore(value: 0)
            let payload = Data(repeating: 91, count: 500_000)
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 7000)
                while received.value.count < payload.count {
                    let n = Darwin.read(peer, &buffer, buffer.count)
                    if n <= 0 { break }
                    received.update { $0.append(contentsOf: buffer.prefix(n)) }
                }
                done.signal()
            }
            try io.writeAll(payload)
            precondition(done.wait(timeout: .now() + 2) == .success)
            check("partial writes preserve the complete payload", received.value == payload)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)
        defer { close(listener) }
        try SocketIO.prepareDescriptor(listener)
        check("listener is nonblocking and closed on exec",
              fcntl(listener, F_GETFL) & O_NONBLOCK != 0 && fcntl(listener, F_GETFD) & FD_CLOEXEC != 0)

        let slots = ConnectionSlots()
        check("128 clients can be admitted", (0..<128).allSatisfy { _ in slots.acquire() })
        check("129th client is rejected", !slots.acquire())
        slots.release()
        check("released slot can be reused", slots.acquire())
        for _ in 0..<128 { slots.release() }
        let group = DispatchGroup(), failures = ResultBox(0)
        for _ in 0..<500 {
            group.enter()
            DispatchQueue.global().async {
                if slots.acquire() { slots.release() } else { failures.update { $0 += 1 } }
                group.leave()
            }
        }
        precondition(group.wait(timeout: .now() + 3) == .success)
        check("concurrent acquire/release leaves no leaked slot", (0..<128).allSatisfy { _ in slots.acquire() } && !slots.acquire())
        for _ in 0..<128 { slots.release() }
        print("ALL \(passed) SOCKET IO CHECKS PASSED")
    }
}
