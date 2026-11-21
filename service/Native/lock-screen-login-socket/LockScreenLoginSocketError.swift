import Foundation

enum LockScreenLoginSocketError: Error, Equatable, CustomStringConvertible {
    case bind(Int32), chmod(Int32), fcntl(Int32), listen(Int32), mkdir(Int32), socket(Int32)
    case directoryIsNotDirectory(String), directoryOwner(String, UInt32), pathTooLong(String), stat(Int32)
    var description: String {
        switch self {
        case .bind(let code): return "bind failed errno=\(code)"
        case .chmod(let code): return "chmod failed errno=\(code)"
        case .fcntl(let code): return "fcntl failed errno=\(code)"
        case .listen(let code): return "listen failed errno=\(code)"
        case .mkdir(let code): return "mkdir failed errno=\(code)"
        case .socket(let code): return "socket failed errno=\(code)"
        case .directoryIsNotDirectory(let path): return "socket directory is not a directory: \(path)"
        case .directoryOwner(let path,let owner): return "socket directory has unexpected owner path=\(path) owner=\(owner)"
        case .pathTooLong(let path): return "socket path is too long: \(path)"
        case .stat(let code): return "stat failed errno=\(code)"
        }
    }
}
