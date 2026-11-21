import Foundation
import Darwin

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var times = [UInt64]()
    let signal = DispatchSemaphore(value: 0)
    func append() { lock.lock(); times.append(DispatchTime.now().uptimeNanoseconds); lock.unlock(); signal.signal() }
    var values: [UInt64] { lock.lock(); defer { lock.unlock() }; return times }
}
private struct CheckFailure: Error { let name: String }

@main enum SocketRetryChecks {
    static func main() {
        var rows = [[String: Any]]()
        func check(_ name: String, _ passed: Bool, _ value: Any = NSNull()) throws {
            rows.append(["name": name, "passed": passed, "observation": value])
            if !passed { throw CheckFailure(name: name) }
        }
        var failure: String?
        do { try run(check) } catch { failure = String(reflecting: error) }
        let result: [String: Any] = ["passed": failure == nil, "checks": rows, "error": failure as Any? ?? NSNull(),
                                   "nativeReferenceExecuted": false, "actualKernelFlockAndTransportUsed": true]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        exit(failure == nil ? 0 : 1)
    }

    static func run(_ check: (String, Bool, Any) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp/cua-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owned.sock").path
        let descriptor = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        precondition(descriptor >= 0)
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        precondition(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let events = Events(), ready = DispatchSemaphore(value: 0)
        let owner = ServiceSocketTransport(path: path, onError: { _ in events.append() }, onListening: { ready.signal() }, makeConnection: { io in
            return {
                do { while let bytes = try io.readExactly(1, until: io.deadline()) { try io.writeAll(bytes) } }
                catch {}
            }
        })
        defer { owner.stop() }
        owner.start()
        for index in 0..<3 {
            try check("real flock causes startup attempt \(index + 1)", events.signal.wait(timeout: .now() + 2) == .success, events.values)
        }
        owner.stop(); owner.start()
        try check("restart under the same lock attempts immediately", events.signal.wait(timeout: .now() + 2) == .success, events.values)
        try check("stop and failed restart preserve the longer native backoff", events.signal.wait(timeout: .now() + 0.35) == .timedOut, events.values)
        try check("the retained backoff eventually retries", events.signal.wait(timeout: .now() + 2) == .success, events.values)
        let recorded = events.values
        try check("the next retry is separated by the 800ms retry schedule", recorded.count == 5 && recorded[4] - recorded[3] >= 600_000_000, recorded)

        precondition(flock(descriptor, LOCK_UN) == 0)
        owner.start()
        try check("manual start recovers before the pending long retry", ready.wait(timeout: .now() + 0.5) == .success, events.values)
        let peer = socket(AF_UNIX, SOCK_STREAM, 0); precondition(peer >= 0)
        defer { close(peer) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        precondition(withUnsafePointer(to: &address) { raw in raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }} == 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        precondition(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        func echo() -> Bool {
            var byte: UInt8 = 71
            return Darwin.write(peer, &byte, 1) == 1 && Darwin.read(peer, &byte, 1) == 1 && byte == 71
        }
        try check("manually recovered listener serves a real connection", echo(), NSNull())
        var identity = stat(); precondition(lstat(path, &identity) == 0)
        Thread.sleep(forTimeInterval: 1.8)
        var later = stat(); let same = lstat(path, &later) == 0 && identity.st_dev == later.st_dev && identity.st_ino == later.st_ino
        try check("old pending retry preserves the healthy socket identity", same && ready.wait(timeout: .now()) == .timedOut && echo(), NSNull())
        owner.stop()
        var byte: UInt8 = 0
        try check("stop closes the manually recovered connection", Darwin.read(peer, &byte, 1) == 0, NSNull())

        precondition(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        owner.start()
        try check("new contention after success begins immediately", events.signal.wait(timeout: .now() + 2) == .success, events.values)
        try check("successful startup resets the next retry to the initial delay", events.signal.wait(timeout: .now() + 0.75) == .success, events.values)
        owner.stop(); precondition(flock(descriptor, LOCK_UN) == 0)
        let stoppedCount = events.values.count
        Thread.sleep(forTimeInterval: 0.35)
        try check("cancelled startup retry cannot resurrect the stopped endpoint", !FileManager.default.fileExists(atPath: path) && events.values.count == stoppedCount, events.values)

        precondition(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        owner.start()
        for _ in 0..<3 { precondition(events.signal.wait(timeout: .now() + 2) == .success) }
        precondition(flock(descriptor, LOCK_UN) == 0)
        let preserved = Data("owned-pending-terminal-file".utf8)
        try preserved.write(to: URL(fileURLWithPath: path))
        owner.start()
        try check("manual terminal failure is reported while an older retry exists", events.signal.wait(timeout: .now() + 2) == .success, events.values)
        try check("manual terminal failure preserves the file at the endpoint", try Data(contentsOf: URL(fileURLWithPath: path)) == preserved, NSNull())
        try FileManager.default.removeItem(atPath: path)
        owner.start()
        try check("clearing the terminal cause permits immediate manual recovery", ready.wait(timeout: .now() + 0.5) == .success, NSNull())
        var recovered = stat(); precondition(lstat(path, &recovered) == 0)
        Thread.sleep(forTimeInterval: 0.55)
        var afterRetry = stat()
        try check("pending retry preserves the listener recovered from a terminal cause", lstat(path, &afterRetry) == 0 && recovered.st_dev == afterRetry.st_dev && recovered.st_ino == afterRetry.st_ino && ready.wait(timeout: .now()) == .timedOut, NSNull())
        let second = socket(AF_UNIX, SOCK_STREAM, 0); precondition(second >= 0)
        defer { close(second) }
        precondition(withUnsafePointer(to: &address) { raw in raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(second, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }} == 0)
        precondition(setsockopt(second, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        var sample: UInt8 = 81
        try check("terminal recovery serves the next real client", Darwin.write(second, &sample, 1) == 1 && Darwin.read(second, &sample, 1) == 1 && sample == 81, NSNull())
        owner.stop()
        try check("terminal recovery still supports final stop", Darwin.read(second, &sample, 1) == 0 && !FileManager.default.fileExists(atPath: path), NSNull())
    }
}
