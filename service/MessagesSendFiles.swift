import Darwin
import Foundation

final class MessagesSendFiles: Sendable {
    let urls: [URL]
    private let directory: URL?

    init(_ attachments: [MessagesIPCSendAttachment], files: [FileHandle], checkpoint: () throws -> Void) throws {
        guard !attachments.isEmpty else {
            urls = []
            directory = nil
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-messages-send-\(UUID())", isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else {
            throw MessagesReadValidationError.invalid("attachment could not be staged")
        }
        do {
            var paths = [URL]()
            for (index, pair) in zip(attachments, files).enumerated() {
                try checkpoint()
                let (attachment, file) = pair
                let source = file.fileDescriptor
                var status = stat()
                guard fstat(source, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    throw MessagesReadValidationError.invalid("attachments must be regular files")
                }
                let parent = root.appendingPathComponent(String(index), isDirectory: true)
                guard mkdir(parent.path, 0o700) == 0 else {
                    throw MessagesReadValidationError.invalid("attachment could not be staged")
                }
                let name = String(attachment.filename.prefix { $0 != "/" })
                let path = parent.appendingPathComponent(name, isDirectory: false)
                let target = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard target >= 0 else {
                    throw MessagesReadValidationError.invalid("attachment could not be staged")
                }
                let copied = lseek(source, 0, SEEK_SET) >= 0 && fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
                let closed = close(target) == 0
                guard copied, closed else {
                    throw MessagesReadValidationError.invalid("attachment could not be staged")
                }
                paths.append(path)
            }
            try checkpoint()
            urls = paths
            directory = root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
