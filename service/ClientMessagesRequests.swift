import Foundation

// Dates and data use Foundation's default Codable wire representations.

enum ComputerUseIPCMessagesService: Codable, Equatable, Sendable {
    case unknown(String), iMessage, sms, rcs, iMessageLite, satelliteSMS

    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    init(raw: String) {
        switch raw {
        case "iMessage": self = .iMessage
        case "SMS": self = .sms
        case "RCS": self = .rcs
        case "iMessageLite": self = .iMessageLite
        case "SatelliteSMS": self = .satelliteSMS
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .iMessage: return "iMessage"
        case .sms: return "SMS"
        case .rcs: return "RCS"
        case .iMessageLite: return "iMessageLite"
        case .satelliteSMS: return "SatelliteSMS"
        case .unknown(let value): return value
        }
    }
}

struct ComputerUseIPCMessagesChat: Codable, Equatable, Sendable {
    var guid: String
    var displayName: String
    var service: ComputerUseIPCMessagesService
    var lastMessageDate: Date
    var participants: [String]
    var unreadCount: Int?
}

struct ComputerUseIPCMessagesChatReference: Codable, Equatable, Sendable {
    var localRef: String
    var guid: String
    var displayName: String
}

struct ComputerUseIPCMessagesChatMetadata: Codable, Equatable, Sendable {
    var guid: String
    var displayName: String
}

struct ComputerUseIPCMessagesParticipant: Codable, Equatable, Sendable {
    var handle: String
    var name: String?
    var service: ComputerUseIPCMessagesService?
}

struct ComputerUseIPCMessagesParticipantReference: Codable, Equatable, Sendable {
    var localRef: String
    var handle: String
    var name: String?
    var service: ComputerUseIPCMessagesService?
}

struct ComputerUseIPCMessagesMessageAttachment: Codable, Equatable, Sendable {
    var id: String
    var filename: String?
    var mimeType: String?
    var sizeBytes: Int?
}

struct ComputerUseIPCMessagesMessage: Codable, Equatable, Sendable {
    var chat: String
    var sender: String
    var body: String?
    var date: Date
    var attachments: [ComputerUseIPCMessagesMessageAttachment]?
    var isUnread: Bool?
}

struct ComputerUseIPCMessagesChatsPage: Codable, Equatable, Sendable {
    var chats: [ComputerUseIPCMessagesChat]
    var participants: [ComputerUseIPCMessagesParticipantReference]
    var hasMore: Bool
}

struct ComputerUseIPCMessagesChatSearchPage: Codable, Equatable, Sendable {
    var chats: [ComputerUseIPCMessagesChatMetadata]
    var hasMore: Bool
}

struct ComputerUseIPCMessagesMessagesPage: Codable, Equatable, Sendable {
    var chats: [ComputerUseIPCMessagesChatReference]
    var senders: [ComputerUseIPCMessagesParticipantReference]
    var messages: [ComputerUseIPCMessagesMessage]
    var nextCursor: String?
}

struct ComputerUseIPCMessagesFindChatsRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesChatsPage
    var participants: [String]
    var exactParticipants: Bool
    var name: String?
    var fromDate: Date?
    var toDate: Date?
    var unreadOnly: Bool
    var limit: Int
}

struct ComputerUseIPCMessagesSearchChatsRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesChatSearchPage
    var query: String
    var limit: Int
}

struct ComputerUseIPCMessagesReadMessagesRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesMessagesPage
    var chatGUID: String
    var fromDate: Date?
    var toDate: Date?
    var unreadOnly: Bool
    var limit: Int
    var cursor: String?
}

struct ComputerUseIPCMessagesSearchMessagesRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesMessagesPage
    var text: String
    var chatGUIDs: [String]
    var participants: [String]
    var exactParticipants: Bool
    var fromDate: Date?
    var toDate: Date?
    var limit: Int
    var cursor: String?
}

enum ComputerUseIPCMessagesSendDestinationKind: String, Codable, Equatable, Sendable {
    case existingChat = "existing_chat"
    case newDirectMessage = "new_direct_message"
    case newGroupMessage = "new_group_message"
}

struct ComputerUseIPCMessagesSendAttachment: Codable, Equatable, Sendable {
    var filename: String
}

struct ComputerUseIPCMessagesPreparedSend: Codable, Equatable, Sendable {
    var planID: UUID
    var chatGUID: String?
    var displayName: String
    var text: String?
    var attachments: [ComputerUseIPCMessagesSendAttachment]
}

struct ComputerUseIPCMessagesPrepareSendRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesPreparedSend
    var chatGUID: String?
    var recipients: [String]
    var text: String?
    var attachments: [ComputerUseIPCMessagesSendAttachment]
}

struct ComputerUseIPCMessagesSendResult: Codable, Equatable, Sendable {
    var destinationKind: ComputerUseIPCMessagesSendDestinationKind
    var chatGUID: String?
    var displayName: String
    var participants: [ComputerUseIPCMessagesParticipant]
    var service: ComputerUseIPCMessagesService?
    var text: String?
    var attachments: [ComputerUseIPCMessagesSendAttachment]
    var sentAt: Date
}

struct ComputerUseIPCMessagesCommitSendRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesSendResult
    var planID: UUID
    var text: String?
}

enum ComputerUseIPCMessagesActivityInterval: String, Codable, Equatable, Sendable {
    case total
    case day
    case week
    case month
    case year
}

enum ComputerUseIPCMessagesActivityChatType: String, Codable, Equatable, Sendable {
    case direct
    case group
}

enum ComputerUseIPCMessagesActivityBreakdown: String, Codable, Equatable, Sendable {
    case overall
    case chat
}

enum ComputerUseIPCMessagesActivityRank: String, Codable, Equatable, Sendable {
    case total
    case sent
    case received
}

struct ComputerUseIPCMessagesActivityRange: Codable, Equatable, Sendable {
    var from: Date
    var to: Date
}

struct ComputerUseIPCMessagesActivityCount: Codable, Equatable, Sendable {
    var total: Int
    var sent: Int
    var received: Int
}

struct ComputerUseIPCMessagesOverallActivity: Codable, Equatable, Sendable {
    var total: Int
    var sent: Int
    var received: Int
    var countsByBucket: [ComputerUseIPCMessagesActivityCount]
}

struct ComputerUseIPCMessagesChatActivity: Codable, Equatable, Sendable {
    var guid: String
    var displayName: String
    var service: ComputerUseIPCMessagesService
    var type: ComputerUseIPCMessagesActivityChatType
    var participants: [String]
    var total: Int
    var sent: Int
    var received: Int
    var countsByBucket: [ComputerUseIPCMessagesActivityCount]
}

struct ComputerUseIPCMessagesActivityResult: Codable, Equatable, Sendable {
    var breakdown: ComputerUseIPCMessagesActivityBreakdown
    var range: ComputerUseIPCMessagesActivityRange
    var interval: ComputerUseIPCMessagesActivityInterval
    var timeZoneIdentifier: String
    var buckets: [ComputerUseIPCMessagesActivityRange]
    var matchingChatCount: Int
    var overallActivity: ComputerUseIPCMessagesOverallActivity?
    var chats: [ComputerUseIPCMessagesChatActivity]?
    var participants: [ComputerUseIPCMessagesParticipantReference]?
    var nextCursor: String?
}

struct ComputerUseIPCMessagesCountActivityRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesActivityResult
    var fromDate: Date?
    var toDate: Date?
    var interval: ComputerUseIPCMessagesActivityInterval
    var chatType: ComputerUseIPCMessagesActivityChatType?
    var chatGUIDs: [String]
    var breakdown: ComputerUseIPCMessagesActivityBreakdown
    var rankBy: ComputerUseIPCMessagesActivityRank
    var chatLimit: Int
    var cursor: String?
}

struct ComputerUseIPCMessagesImage: Codable, Equatable, Sendable {
    var data: Data
    var mimeType: String
    var chatGUID: String
    var chatDisplayName: String
}

struct ComputerUseIPCMessagesReadImageRequest: ComputerUseIPCRequest, Equatable, Sendable {
    typealias Response = ComputerUseIPCMessagesImage
    var id: String
}

