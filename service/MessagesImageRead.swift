import Darwin
import Foundation

enum MessagesImageRead {
    struct Attachment {
        var path: String
        var chatGUID: String
        var chatDisplayName: String
    }

    // Resolution must match both row IDs in the database. The request never
    // supplies a filesystem path.
    static func read(_ request: MessagesIPCReadImageRequest,
                     resolve: (MessagesAttachmentID) throws -> Attachment?) throws -> MessagesIPCImage {
        guard let id = MessagesAttachmentID(encoded: request.id) else {
            throw MessagesReadValidationError.invalid("image attachment id is invalid")
        }
        guard let attachment = try resolve(id), let bytes = try readFile(attachment.path) else {
            throw MessagesReadValidationError.invalid("image attachment is unavailable")
        }
        let image = try MessagesImageProcessor.process(bytes)
        return .init(data: image.data, mimeType: image.mimeType, chatGUID: attachment.chatGUID,
                     chatDisplayName: attachment.chatDisplayName)
    }

    private static func readFile(_ path: String) throws -> Data? {
        let expanded = (path as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath, !expanded.utf8.contains(0) else { return nil }
        let fd = open(expanded, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let limit = MessagesImageProcessor.maximumInputBytes
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size <= limit else { return nil }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while data.count <= limit {
            let count = min(64 * 1024, limit + 1 - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        return nil
    }
}
