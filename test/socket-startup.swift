import Foundation
import Darwin

@main enum SocketStartupTests {
    static func main() throws {
        var passed = 0
        func check(_ label: String, _ value: Bool) {
            precondition(value, label); passed += 1
        }
        for code: Int32 in 0...255 {
            check("native lock error is retryable", ServiceSocketStartupPolicy.canRetry(ServiceSocketListenerError.lockFailed(code)))
            check("only EADDRINUSE from bind is retryable",
                  ServiceSocketStartupPolicy.canRetry(ServiceSocketListenerError.bindFailed(code)) == (code == EADDRINUSE))
            check("other system-error stages do not become retryable", !ServiceSocketStartupPolicy.canRetry(SocketIOError.system(code)))
        }
        check("existing active endpoint is retryable", ServiceSocketStartupPolicy.canRetry(ServiceSocketListenerError.alreadyRunning))
        for error in [ServiceSocketListenerError.unsafeDirectory,.unsafeNode,.wrongOwner,.nodeChanged,.pathTooLong] {
            check("permanent listener errors are terminal", !ServiceSocketStartupPolicy.canRetry(error))
        }
        check("unrelated Cocoa errors are terminal", !ServiceSocketStartupPolicy.canRetry(NSError(domain: "owned", code: Int(EADDRINUSE))))
        for (attempt, delay) in [(-1,0),(0,100),(1,200),(2,400),(3,800),(4,1600),(5,3200),(6,5000),(7,5000),(20,5000),(Int.max,5000)] {
            check("retry backoff including cap", ServiceSocketStartupPolicy.delayMilliseconds(attempt: attempt) == delay)
        }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("cua-startup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owned.sock").path
        let lock = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        precondition(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { close(lock) }
        var delays = [TimeInterval](), errors = 0
        var listener = ServiceSocketListener.openWithRecovery(path: path, wait: { delay in
            delays.append(delay)
            if delays.count == 9 { precondition(flock(lock, LOCK_UN) == 0) }
        }, onError: { _ in errors += 1 })
        check("real lock contention recovers without a retry-count limit", listener != nil && errors == 9)
        check("every retry follows the doubling delay sequence", delays == [0.1,0.2,0.4,0.8,1.6,3.2,5,5,5])
        withExtendedLifetime(listener) {}; listener = nil
        precondition(flock(lock, LOCK_EX | LOCK_NB) == 0)
        var running = true; errors = 0; delays = []
        listener = ServiceSocketListener.openWithRecovery(path: path, shouldContinue: { running }, wait: {
            delays.append($0); running = false
        }, onError: { _ in errors += 1 })
        check("cancellation prevents another attempt after a queued delay", listener == nil && errors == 1 && delays == [0.1])
        precondition(flock(lock, LOCK_UN) == 0)
        let content = Data("owned-file".utf8)
        try content.write(to: URL(fileURLWithPath: path))
        errors = 0; delays = []
        listener = ServiceSocketListener.openWithRecovery(path: path, wait: { delays.append($0) }, onError: { _ in errors += 1 })
        check("permanent file conflict returns after exactly one failure", listener == nil && errors == 1 && delays.isEmpty)
        check("permanent startup error preserves the conflicting file", try Data(contentsOf: URL(fileURLWithPath: path)) == content)
        errors = 0
        listener = ServiceSocketListener.openWithRecovery(path: path, shouldContinue: { false }, onError: { _ in errors += 1 })
        check("already-cancelled startup performs no attempt", listener == nil && errors == 0)
        print("ALL \(passed) SOCKET STARTUP CHECKS PASSED")
    }
}
