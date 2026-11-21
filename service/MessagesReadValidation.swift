import Foundation

enum MessagesReadValidationError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum MessagesReadValidation {
    static func findChats(_ input: MessagesIPCFindChatsRequest) throws -> MessagesIPCFindChatsRequest? {
        try participants(input.participants, exact: input.exactParticipants)
        guard input.limit > 0 else { return nil }
        var query = input
        query.limit = min(input.limit, 100)
        query.name = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return query
    }

    static func searchChats(_ input: MessagesIPCSearchChatsRequest) -> MessagesIPCSearchChatsRequest? {
        guard input.limit > 0 else { return nil }
        var query = input
        query.limit = min(input.limit, 100)
        query.query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query
    }

    static func readMessages(_ input: MessagesIPCReadMessagesRequest) throws -> MessagesIPCReadMessagesRequest? {
        var query = input
        query.chatGUID = input.chatGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.chatGUID.isEmpty else {
            throw MessagesReadValidationError.invalid("chatGUID must not be empty")
        }
        guard input.limit > 0 else { return nil }
        query.limit = min(input.limit, 100)
        return query
    }

    static func searchMessages(_ input: MessagesIPCSearchMessagesRequest) throws -> MessagesIPCSearchMessagesRequest? {
        var query = input
        query.text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.text.isEmpty else {
            throw MessagesReadValidationError.invalid("text must not be empty")
        }
        try participants(input.participants, exact: input.exactParticipants)
        guard input.limit > 0 else { return nil }
        query.chatGUIDs = Set(input.chatGUIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).sorted()
        guard !query.chatGUIDs.contains(where: \.isEmpty) else {
            throw MessagesReadValidationError.invalid("chatGUIDs must not contain empty values")
        }
        query.participants.sort()
        query.limit = min(input.limit, 100)
        return query
    }

    private static func participants(_ values: [String], exact: Bool) throws {
        if exact && values.isEmpty {
            throw MessagesReadValidationError.invalid("exactParticipants requires at least one participant")
        }
    }
}

struct MessagesAttachmentID: Equatable {
    let attachmentRowID: Int64
    let chatRowID: Int64

    init?(attachmentRowID: Int64, chatRowID: Int64) {
        guard attachmentRowID > 0, chatRowID > 0 else { return nil }
        self.attachmentRowID = attachmentRowID
        self.chatRowID = chatRowID
    }

    init?(encoded: String) {
        guard encoded.utf8.count == 24, let bytes = Data(base64Encoded: encoded),
              bytes.count == 17, bytes.first == 2 else { return nil }
        let ids = bytes.withUnsafeBytes { raw in
            (Int64(bigEndian: raw.loadUnaligned(fromByteOffset: 1, as: Int64.self)),
             Int64(bigEndian: raw.loadUnaligned(fromByteOffset: 9, as: Int64.self)))
        }
        self.init(attachmentRowID: ids.0, chatRowID: ids.1)
    }

    var encoded: String {
        var bytes = Data([2])
        for id in [attachmentRowID, chatRowID] {
            var bigEndian = id.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes.base64EncodedString()
    }
}
