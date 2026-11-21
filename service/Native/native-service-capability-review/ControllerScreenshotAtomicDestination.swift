import Darwin
import Foundation
import ImageIO

/// ImageIO can report success for a partially written PNG. Encode independently
/// of the filesystem, then publish only after all bytes have been written.
final class ControllerScreenshotAtomicDestination {
    enum PublicationError: Error { case collision }

    private let url: URL
    private let temporaryPath: String
    private let data: CFMutableData
    private let encoder: CGImageDestination
    private var fd: Int32
    private var published = false

    private init(url: URL, temporaryPath: String, fd: Int32, data: CFMutableData, encoder: CGImageDestination) {
        self.url = url
        self.temporaryPath = temporaryPath
        self.fd = fd
        self.data = data
        self.encoder = encoder
    }

    static func make(_ url: URL, encoding: ControllerScreenshotEncoding) -> ControllerScreenshotAtomicDestination? {
        let prefix = url.deletingLastPathComponent().appendingPathComponent(".cua-image-XXXXXX").path
        var path = prefix.utf8CString
        let fd = path.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { return nil }
        let temporaryPath = String(decoding: path.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              let data = CFDataCreateMutable(nil, 0),
              let encoder = CGImageDestinationCreateWithData(data, encoding.type.identifier as CFString, 1, nil)
        else {
            _ = close(fd)
            _ = unlink(temporaryPath)
            return nil
        }
        return .init(url: url, temporaryPath: temporaryPath, fd: fd, data: data, encoder: encoder)
    }

    func finalize(_ image: CGImage, encoding: ControllerScreenshotEncoding) throws {
        guard ControllerScreenshotImageIO.addAndFinalize(encoder, image, encoding) else { throw POSIXError(.EIO) }
        let length = CFDataGetLength(data)
        guard length > 0, let bytes = CFDataGetBytePtr(data) else { throw POSIXError(.EIO) }
        var offset = 0
        while offset < length {
            let count = Darwin.write(fd, bytes.advanced(by: offset), length - offset)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw Self.error(code)
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
        while fsync(fd) != 0 {
            let code = errno
            if code != EINTR { throw Self.error(code) }
        }
        let closing = fd
        fd = -1
        guard close(closing) == 0 else { throw Self.error(errno) }
        guard renamex_np(temporaryPath, url.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw PublicationError.collision }
            throw Self.error(code)
        }
        published = true
    }

    deinit {
        if fd >= 0 { _ = close(fd) }
        if !published { _ = unlink(temporaryPath) }
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
