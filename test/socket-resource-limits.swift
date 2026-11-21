import Foundation
import Darwin

// This executable is a disposable receiver. The Python driver sends real
// SCM_RIGHTS before this process lowers only its own descriptor limit.
@main enum SocketResourceLimitChecks {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 5, let descriptor = Int32(args[1]), let count = Int(args[2]),
              let headroom = Int(args[3]), ["header", "body"].contains(args[4]) else { exit(64) }
        alarm(10)
        let limit = 512
        var ballast = [Int32](), files = [FileHandle]()
        var result = [String: Any]()
        var success = false
        do {
            let io = try SocketIO(fd: descriptor, timeout: .seconds(2))
            var budget = rlimit(rlim_cur: rlim_t(limit), rlim_max: rlim_t(limit))
            guard setrlimit(RLIMIT_NOFILE, &budget) == 0 else { throw SocketIOError.system(errno) }
            while true {
                let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
                if fd < 0 {
                    guard errno == EMFILE else { throw SocketIOError.system(errno) }
                    break
                }
                ballast.append(fd)
            }
            guard headroom <= ballast.count else { throw SocketIOError.system(EINVAL) }
            for _ in 0..<headroom { close(ballast.removeLast()) }
            let before = (0..<limit).map { fcntl(Int32($0), F_GETFD) >= 0 }
            let beforeCount = before.filter { $0 }.count
            var header: Data?, body: Data?, receiveError: Int32?
            do {
                header = try io.readExactly(4, until: io.deadline(), files: &files)
                body = try io.readExactly(32, until: io.deadline(), files: &files)
            } catch SocketIOError.system(let code) { receiveError = code }
            let expected = count <= headroom
            let exact = header == Data([32, 0, 0, 0]) && body == Data((1...32).map(UInt8.init))
            let collected = files.count
            let cloexec = files.allSatisfy { fcntl($0.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0 }
            let installed = (0..<limit).filter { !before[$0] && fcntl(Int32($0), F_GETFD) >= 0 }.count
            for file in files { try file.close() }
            files.removeAll()
            let leaked = (0..<limit).filter { !before[$0] && fcntl(Int32($0), F_GETFD) >= 0 }.count
            let afterCount = (0..<limit).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
            success = beforeCount == limit - headroom && exact == expected
                && receiveError == (expected ? nil : EMSGSIZE)
                && collected == (expected ? count : 0) && installed == collected
                && cloexec && leaked == 0 && afterCount == beforeCount
            result = ["passed": success, "count": count, "headroom": headroom, "location": args[4],
                      "exactFrame": exact, "receiveError": receiveError as Any? ?? NSNull(),
                      "collected": collected, "installed": installed, "allCloseOnExec": cloexec,
                      "leakedAfterCleanup": leaked, "beforeCount": beforeCount, "afterCount": afterCount]
        } catch {
            result = ["passed": false, "error": String(reflecting: error)]
        }
        for file in files { try? file.close() }
        for fd in ballast { close(fd) }
        close(descriptor)
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        exit(success ? 0 : 1)
    }
}
