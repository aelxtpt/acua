import Foundation
import Darwin
import Dispatch

struct LockScreenLoginSocketAddress {
    var address: sockaddr_un
    let length: socklen_t
    init(path: String) throws {
        let bytes = Array(path.utf8)
        guard bytes.count <= 103 else { throw LockScreenLoginSocketError.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of:&address.sun_path) { buffer in
            for (index,byte) in (bytes + [0]).enumerated() { buffer[index] = byte }
        }
        self.address = address; length = socklen_t(bytes.count + 3)
    }
}

@MainActor struct LockScreenLoginReadSource {
    var resume: () -> Void
    var cancel: () -> Void
}
@MainActor struct LockScreenLoginSocketIO {
    struct DirectoryInfo { let mode: mode_t; let owner: uid_t }
    var socket: () -> Int32
    var mkdir: (String, mode_t) -> Int32
    var lstat: (String) -> DirectoryInfo?
    var effectiveUID: () -> uid_t
    var getFlags: (Int32) -> Int32
    var setFlags: (Int32, Int32) -> Int32
    var unlink: (String) -> Void
    var bind: (Int32, LockScreenLoginSocketAddress) -> Int32
    var chmod: (String, mode_t) -> Int32
    var listen: (Int32, Int32) -> Int32
    var readSource: (Int32, @escaping @MainActor @Sendable () -> Void) -> LockScreenLoginReadSource
    var accept: (Int32) -> Int32
    var write: (Int32, Data) -> Int
    var close: (Int32) -> Void
    var error: () -> Int32

    static var native: Self {
        .init(socket:{ Darwin.socket(AF_UNIX,SOCK_STREAM,0) },
            mkdir:{ path,mode in path.withCString { Darwin.mkdir($0,mode) } },
            lstat:{ path in
                var info = Darwin.stat()
                guard path.withCString({ Darwin.lstat($0,&info) }) == 0 else { return nil }
                return .init(mode:info.st_mode,owner:info.st_uid)
            }, effectiveUID:geteuid,
            getFlags:{ fcntl($0,F_GETFL) },setFlags:{ fcntl($0,F_SETFL,$1) },
            unlink:{ path in _ = path.withCString { Darwin.unlink($0) } },
            bind:{ fd,raw in
                var raw = raw
                return withUnsafePointer(to:&raw.address) { pointer in
                    pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,raw.length) }
                }
            },chmod:{ path,mode in path.withCString { Darwin.chmod($0,mode) } },listen:Darwin.listen,
            readSource:{ fd,callback in
                let source = DispatchSource.makeReadSource(fileDescriptor:fd,queue:.main)
                source.setEventHandler { MainActor.assumeIsolated { callback() } }
                return .init(resume:{source.resume()},cancel:{source.cancel()})
            },accept:{ Darwin.accept($0,nil,nil) },write:{ fd,data in
                data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,$0.count) }
            },close:{ _ = Darwin.close($0) },error:{ errno })
    }
}
