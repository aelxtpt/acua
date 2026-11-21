import Foundation
import MCP

struct MessagesMCPParticipant: Encodable, Sendable {
    let handle: String
    let name: String?
    let service: String?
}
struct MessagesMCPParticipantReference: Encodable, Sendable {
    let localRef: String
    let handle: String
    let name: String?
    let service: String?
    init(_ value: ComputerUseIPCMessagesParticipantReference) {
        localRef = value.localRef; handle = value.handle; name = value.name; service = value.service?.rawValue
    }
}
struct MessagesMCPChat: Encodable, Sendable {
    let chatGUID: String
    let displayName: String
    let service: String
    let lastMessageDate: Date
    let participants: [String]
    let unreadCount: Int?
}
struct MessagesMCPChatsPage: Encodable, Sendable {
    let chats: [MessagesMCPChat]
    let participants: [MessagesMCPParticipantReference]
    let hasMore: Bool
}
struct MessagesMCPChatReference: Encodable, Sendable {
    let localRef: String
    let chatGUID: String
    let displayName: String
}
struct MessagesMCPAttachment: Encodable, Sendable {
    let id: String
    let filename: String?
    let mimeType: String?
    let sizeBytes: Int?
}
struct MessagesMCPMessage: Encodable, Sendable {
    let chat: String
    let sender: String
    let body: String?
    let date: Date
    let attachments: [MessagesMCPAttachment]?
    let isUnread: Bool?
}
struct MessagesMCPMessagesPage: Encodable, Sendable {
    let chats: [MessagesMCPChatReference]
    let senders: [MessagesMCPParticipantReference]
    let messages: [MessagesMCPMessage]
    let nextCursor: String?
    let permissionFiltered: Bool?
    let permissionFilterMessage: String?
}
struct MessagesMCPSendResult: Encodable, Sendable {
    let destinationKind: String
    let chatGUID: String?
    let displayName: String
    let participants: [MessagesMCPParticipant]
    let service: String?
    let text: String?
    let attachments: [ComputerUseIPCMessagesSendAttachment]
    let sentAt: Date
    let userEdited: Bool?
}
struct MessagesMCPActivityCountsByBucket: Encodable, Sendable {
    let total: [Int]
    let sent: [Int]
    let received: [Int]
    init(_ values: [ComputerUseIPCMessagesActivityCount]) {
        total = values.map(\.total); sent = values.map(\.sent); received = values.map(\.received)
    }
}
struct MessagesMCPOverallActivity: Encodable, Sendable {
    let total: Int
    let sent: Int
    let received: Int
    let countsByBucket: MessagesMCPActivityCountsByBucket
}
struct MessagesMCPChatActivity: Encodable, Sendable {
    let chatGUID: String
    let displayName: String
    let service: ComputerUseIPCMessagesService
    let type: ComputerUseIPCMessagesActivityChatType
    let participants: [String]
    let total: Int
    let sent: Int
    let received: Int
    let countsByBucket: MessagesMCPActivityCountsByBucket
}
struct MessagesMCPActivityResult: Encodable, Sendable {
    let breakdown: ComputerUseIPCMessagesActivityBreakdown
    let range: ComputerUseIPCMessagesActivityRange
    let interval: ComputerUseIPCMessagesActivityInterval
    let timeZone: String
    let buckets: [ComputerUseIPCMessagesActivityRange]
    let matchingChatCount: Int
    let overallActivity: MessagesMCPOverallActivity?
    let chats: [MessagesMCPChatActivity]?
    let participants: [MessagesMCPParticipantReference]?
    let nextCursor: String?

    func validate() throws {
        let valid: Bool
        switch breakdown {
        case .overall: valid = overallActivity != nil && chats == nil && participants == nil && nextCursor == nil
        case .chat: valid = overallActivity == nil && chats != nil && participants != nil
        }
        guard valid else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Activity result does not match its breakdown"))
        }
    }
}

enum MessagesMCPFormatting {
    static func format<T: Encodable>(_ value: T, structured: Bool) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let structuredContent: Value? = structured ? try JSONDecoder().decode(Value.self, from: data) : .some(.null)
        return .init(content: [.text(String(decoding: data, as: UTF8.self))],
            structuredContent: structuredContent)
    }
    static func chats(_ page: ComputerUseIPCMessagesChatsPage) throws -> CallTool.Result {
        try format(MessagesMCPChatsPage(chats: page.chats.map {
            .init(chatGUID: $0.guid, displayName: $0.displayName, service: $0.service.rawValue,
                  lastMessageDate: $0.lastMessageDate, participants: $0.participants, unreadCount: $0.unreadCount)
        }, participants: page.participants.map(MessagesMCPParticipantReference.init), hasMore: page.hasMore), structured: true)
    }
    static func messages(_ page: ComputerUseIPCMessagesMessagesPage,
                         permissionFiltered: Bool? = nil, permissionFilterMessage: String? = nil) throws -> CallTool.Result {
        try format(MessagesMCPMessagesPage(chats: page.chats.map {
            .init(localRef: $0.localRef, chatGUID: $0.guid, displayName: $0.displayName)
        }, senders: page.senders.map(MessagesMCPParticipantReference.init), messages: page.messages.map {
            .init(chat: $0.chat, sender: $0.sender, body: $0.body, date: $0.date,
                attachments: $0.attachments?.map { .init(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, sizeBytes: $0.sizeBytes) },
                isUnread: $0.isUnread == true ? true : nil)
        }, nextCursor: page.nextCursor, permissionFiltered: permissionFiltered, permissionFilterMessage: permissionFilterMessage), structured: true)
    }
    static func sent(_ result: ComputerUseIPCMessagesSendResult, userEdited: Bool) throws -> CallTool.Result {
        try format(MessagesMCPSendResult(destinationKind: result.destinationKind.rawValue, chatGUID: result.chatGUID,
            displayName: result.displayName, participants: result.participants.map {
                .init(handle: $0.handle, name: $0.name, service: $0.service?.rawValue)
            }, service: result.service?.rawValue, text: result.text, attachments: result.attachments,
            sentAt: result.sentAt, userEdited: userEdited ? true : nil), structured: false)
    }
    static func activity(_ result: ComputerUseIPCMessagesActivityResult) throws -> CallTool.Result {
        let value = MessagesMCPActivityResult(breakdown: result.breakdown, range: result.range, interval: result.interval,
            timeZone: result.timeZoneIdentifier, buckets: result.buckets, matchingChatCount: result.matchingChatCount,
            overallActivity: result.overallActivity.map {
                .init(total: $0.total, sent: $0.sent, received: $0.received, countsByBucket: .init($0.countsByBucket))
            }, chats: result.chats?.map {
                .init(chatGUID: $0.guid, displayName: $0.displayName, service: $0.service, type: $0.type,
                    participants: $0.participants, total: $0.total, sent: $0.sent, received: $0.received, countsByBucket: .init($0.countsByBucket))
            }, participants: result.participants?.map(MessagesMCPParticipantReference.init), nextCursor: result.nextCursor)
        try value.validate()
        return try format(value, structured: true)
    }
    static func image(_ image: ComputerUseIPCMessagesImage) -> CallTool.Result {
        .init(content: [.image(data: image.data.base64EncodedString(), mimeType: image.mimeType, metadata: nil)])
    }
    static func error(_ error: any Error, toolName: String) -> CallTool.Result {
        if case ComputerUseIPCClient.Error.messagesPermissionsPending = error {
            let message = String(describing: error)
            let hasOutputSchema = ["find_chats", "read_messages", "search_messages", "count_message_activity"].contains(toolName)
            return .init(content: [.text(message)], structuredContent: hasOutputSchema ? .object(["message": .string(message)]) : nil)
        }
        return .init(content: [.text(String(describing: error))], isError: true)
    }
}
