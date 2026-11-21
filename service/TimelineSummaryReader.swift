import Foundation
import Darwin

struct TimelineSummaryReader {
    func read(_ summary: TimelineSummaryFile, directoryFD: Int32) throws -> (filename: String, contents: String) {
        let filename = summary.url.lastPathComponent
        let failure = TimelineSummaryError.invalidChildSummary(filename)
        let fd = openat(directoryFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw failure }
        do {
            let data = try handle.readToEnd() ?? Data()
            guard let contents = String(data: data, encoding: .utf8) else { throw failure }
            return (filename, contents)
        } catch { throw failure }
    }
}
