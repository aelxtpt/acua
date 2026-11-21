import Foundation
import Darwin
import MCP

struct MessagesMCPSendArguments: Sendable {
    let request: ComputerUseIPCMessagesPrepareSendRequest
    let files: [FileHandle]
}

/// Shared scalar validation uses the same helpers as Calendar.
/// Cross-field checks remain domain specific and precede native discovery.
struct MessagesMCPArguments {
    let input: CalendarMCPArguments
    init(_ values: [String: Value]?) { input = .init(values) }

    func strings(_ key: String, minimum: Int = 0, maximum: Int = 20) throws -> [String] {
        guard let value = input.values[key] else { return [] }
        guard case .array(let array) = value else {
            throw CalendarMCPArgumentError.invalid(key + " must be an array of strings")
        }
        guard (minimum...maximum).contains(array.count) else {
            throw CalendarMCPArgumentError.invalid(key + " must contain between \(minimum) and \(maximum) values")
        }
        return try input.strings(key)
    }
    func integer(_ key: String, default fallback: Int) throws -> Int {
        guard let value = input.values[key] else { return fallback }
        guard case .int(let number) = value, (1...100).contains(number) else {
            throw CalendarMCPArgumentError.invalid(key + " must be an integer between 1 and 100")
        }
        return number
    }
    func enumeration<T: RawRepresentable>(_ key: String, default fallback: T?) throws -> T? where T.RawValue == String {
        guard let string = try input.string(key) else { return fallback }
        guard let value = T(rawValue: string) else { throw CalendarMCPArgumentError.invalid(key + " has an unsupported value") }
        return value
    }
    func participants() throws -> (values: [String], exact: Bool) {
        let values = try strings("participants")
        let exact = try input.boolean("exact_participants") ?? false
        guard !exact || !values.isEmpty else {
            throw CalendarMCPArgumentError.invalid("exact_participants requires at least one participant")
        }
        return (values, exact)
    }
    func findChats() throws -> ComputerUseIPCMessagesFindChatsRequest {
        try input.rejectUnknown(["participants", "exact_participants", "name", "from", "to", "unread_only", "limit"])
        let participants = try participants()
        return try .init(participants: participants.values, exactParticipants: participants.exact,
            name: input.string("name"), fromDate: input.date("from"), toDate: input.date("to"),
            unreadOnly: input.boolean("unread_only") ?? false, limit: integer("limit", default: 20))
    }
    func readMessages() throws -> ComputerUseIPCMessagesReadMessagesRequest {
        try input.rejectUnknown(["chat_guid", "from", "to", "unread_only", "limit", "cursor"])
        return try .init(chatGUID: input.requiredString("chat_guid"), fromDate: input.date("from"), toDate: input.date("to"),
            unreadOnly: input.boolean("unread_only") ?? false, limit: integer("limit", default: 50), cursor: input.string("cursor"))
    }
    func searchMessages() throws -> ComputerUseIPCMessagesSearchMessagesRequest {
        try input.rejectUnknown(["text", "participants", "exact_participants", "chat_guids", "from", "to", "limit", "cursor"])
        let participants = try participants()
        return try .init(text: input.requiredString("text"), chatGUIDs: strings("chat_guids"), participants: participants.values,
            exactParticipants: participants.exact, fromDate: input.date("from"), toDate: input.date("to"),
            limit: integer("limit", default: 50), cursor: input.string("cursor"))
    }
    func countActivity() throws -> ComputerUseIPCMessagesCountActivityRequest {
        try input.rejectUnknown(["from", "to", "interval", "chat_type", "chat_guids", "breakdown", "rank_by", "chat_limit", "cursor"])
        let breakdown = try enumeration("breakdown", default: ComputerUseIPCMessagesActivityBreakdown.overall)!
        if breakdown == .overall {
            let prohibited = ["rank_by", "chat_limit", "cursor"].filter { input.values[$0] != nil }
            guard prohibited.isEmpty else {
                throw CalendarMCPArgumentError.invalid(prohibited.joined(separator: ", ") + " can only be used when breakdown is chat")
            }
        }
        return try .init(fromDate: input.date("from"), toDate: input.date("to"),
            interval: enumeration("interval", default: ComputerUseIPCMessagesActivityInterval.total)!,
            chatType: enumeration("chat_type", default: Optional<ComputerUseIPCMessagesActivityChatType>.none),
            chatGUIDs: strings("chat_guids", minimum: input.values["chat_guids"] == nil ? 0 : 1), breakdown: breakdown,
            rankBy: enumeration("rank_by", default: ComputerUseIPCMessagesActivityRank.total)!,
            chatLimit: integer("chat_limit", default: 20), cursor: input.string("cursor"))
    }
    func readImage() throws -> ComputerUseIPCMessagesReadImageRequest {
        try input.rejectUnknown(["id"])
        return try .init(id: input.requiredString("id"))
    }
    func sendMessage() throws -> MessagesMCPSendArguments {
        try input.rejectUnknown(["chat_guid", "recipients", "text", "attachments"])
        let chat = try input.string("chat_guid")
        let recipients = try strings("recipients", minimum: input.values["recipients"] == nil ? 0 : 1)
        let text = try input.string("text")
        if let text, text.count > 10_000 {
            throw CalendarMCPArgumentError.invalid("text must be no more than 10000 characters")
        }
        let paths = try strings("attachments", minimum: input.values["attachments"] == nil ? 0 : 1, maximum: 10)
        guard (chat != nil) != !recipients.isEmpty else {
            throw CalendarMCPArgumentError.invalid("provide exactly one of chat_guid or recipients")
        }
        guard text != nil || !paths.isEmpty else {
            throw CalendarMCPArgumentError.invalid("provide text, attachments, or both")
        }
        guard paths.allSatisfy({ ($0 as NSString).isAbsolutePath }) else {
            throw CalendarMCPArgumentError.invalid("attachments must contain only absolute local file paths")
        }
        var attachments: [ComputerUseIPCMessagesSendAttachment] = []
        var files: [FileHandle] = []
        for path in paths {
            let filename = (path as NSString).lastPathComponent
            let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else {
                throw CalendarMCPArgumentError.invalid("an attachment could not be opened by the Messages client: " + filename)
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(descriptor)
                throw CalendarMCPArgumentError.invalid("attachments must be regular files: " + filename)
            }
            attachments.append(.init(filename: filename))
            files.append(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        }
        return .init(request: .init(chatGUID: chat, recipients: recipients, text: text, attachments: attachments), files: files)
    }
}
