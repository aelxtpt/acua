import Foundation

// Dates and data use Foundation's default Codable wire representations.

enum MessagesIPCService: Codable, Equatable, Sendable {
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

struct MessagesIPCChat: Codable, Equatable {
    var guid: String
    var displayName: String
    var service: MessagesIPCService
    var lastMessageDate: Date
    var participants: [String]
    var unreadCount: Int?
}

struct MessagesIPCChatReference: Codable, Equatable {
    var localRef: String
    var guid: String
    var displayName: String
}

struct MessagesIPCChatMetadata: Codable, Equatable {
    var guid: String
    var displayName: String
}

struct MessagesIPCParticipant: Codable, Equatable, Sendable {
    var handle: String
    var name: String?
    var service: MessagesIPCService?
}

struct MessagesIPCParticipantReference: Codable, Equatable {
    var localRef: String
    var handle: String
    var name: String?
    var service: MessagesIPCService?
}

struct MessagesIPCMessageAttachment: Codable, Equatable {
    var id: String
    var filename: String?
    var mimeType: String?
    var sizeBytes: Int?
}

struct MessagesIPCMessage: Codable, Equatable {
    var chat: String
    var sender: String
    var body: String?
    var date: Date
    var attachments: [MessagesIPCMessageAttachment]?
    var isUnread: Bool?
}

struct MessagesIPCChatsPage: Codable, Equatable {
    var chats: [MessagesIPCChat]
    var participants: [MessagesIPCParticipantReference]
    var hasMore: Bool
}

struct MessagesIPCChatSearchPage: Codable, Equatable {
    var chats: [MessagesIPCChatMetadata]
    var hasMore: Bool
}

struct MessagesIPCMessagesPage: Codable, Equatable {
    var chats: [MessagesIPCChatReference]
    var senders: [MessagesIPCParticipantReference]
    var messages: [MessagesIPCMessage]
    var nextCursor: String?
}

struct MessagesIPCFindChatsRequest: Codable, Equatable, Sendable {
    var participants: [String]
    var exactParticipants: Bool
    var name: String?
    var fromDate: Date?
    var toDate: Date?
    var unreadOnly: Bool
    var limit: Int
}

struct MessagesIPCSearchChatsRequest: Codable, Equatable, Sendable {
    var query: String
    var limit: Int
}

struct MessagesIPCReadMessagesRequest: Codable, Equatable, Sendable {
    var chatGUID: String
    var fromDate: Date?
    var toDate: Date?
    var unreadOnly: Bool
    var limit: Int
    var cursor: String?
}

struct MessagesIPCSearchMessagesRequest: Codable, Equatable, Sendable {
    var text: String
    var chatGUIDs: [String]
    var participants: [String]
    var exactParticipants: Bool
    var fromDate: Date?
    var toDate: Date?
    var limit: Int
    var cursor: String?
}

enum MessagesIPCSendDestinationKind: String, Codable, Equatable, Sendable {
    case existingChat = "existing_chat"
    case newDirectMessage = "new_direct_message"
    case newGroupMessage = "new_group_message"
}

struct MessagesIPCSendAttachment: Codable, Equatable, Sendable {
    var filename: String
}

struct MessagesIPCPreparedSend: Codable, Equatable {
    var planID: UUID
    var chatGUID: String?
    var displayName: String
    var text: String?
    var attachments: [MessagesIPCSendAttachment]
}

struct MessagesIPCPrepareSendRequest: Codable, Equatable, Sendable {
    var chatGUID: String?
    var recipients: [String]
    var text: String?
    var attachments: [MessagesIPCSendAttachment]
}

struct MessagesIPCSendResult: Codable, Equatable {
    var destinationKind: MessagesIPCSendDestinationKind
    var chatGUID: String?
    var displayName: String
    var participants: [MessagesIPCParticipant]
    var service: MessagesIPCService?
    var text: String?
    var attachments: [MessagesIPCSendAttachment]
    var sentAt: Date
}

enum MessagesIPCSendPlanUnavailableReason: String, Codable, Equatable, Sendable {
    case missing
    case expired
    case alreadyConsumed = "already_consumed"
}

struct MessagesIPCCommitSendRequest: Codable, Equatable, Sendable {
    var planID: UUID
    var text: String?
}

typealias MessagesIPCActivityInterval = ComputerUseIPCMessagesActivityInterval
enum ComputerUseIPCMessagesActivityInterval: String, Codable, Equatable, Sendable {
    case total
    case day
    case week
    case month
    case year
}

typealias MessagesIPCActivityChatType = ComputerUseIPCMessagesActivityChatType
enum ComputerUseIPCMessagesActivityChatType: String, Codable, Equatable, Sendable {
    case direct
    case group
}

typealias MessagesIPCActivityBreakdown = ComputerUseIPCMessagesActivityBreakdown
enum ComputerUseIPCMessagesActivityBreakdown: String, Codable, Equatable, Sendable {
    case overall
    case chat
}

typealias MessagesIPCActivityRank = ComputerUseIPCMessagesActivityRank
enum ComputerUseIPCMessagesActivityRank: String, Codable, Equatable, Sendable {
    case total
    case sent
    case received
}

struct MessagesIPCActivityRange: Codable, Equatable {
    var from: Date
    var to: Date
}

struct MessagesIPCActivityCount: Codable, Equatable {
    var total: Int
    var sent: Int
    var received: Int
}

struct MessagesIPCOverallActivity: Codable, Equatable {
    var total: Int
    var sent: Int
    var received: Int
    var countsByBucket: [MessagesIPCActivityCount]
}

struct MessagesIPCChatActivity: Codable, Equatable {
    var guid: String
    var displayName: String
    var service: MessagesIPCService
    var type: MessagesIPCActivityChatType
    var participants: [String]
    var total: Int
    var sent: Int
    var received: Int
    var countsByBucket: [MessagesIPCActivityCount]
}

struct MessagesIPCActivityResult: Codable, Equatable {
    var breakdown: MessagesIPCActivityBreakdown
    var range: MessagesIPCActivityRange
    var interval: MessagesIPCActivityInterval
    var timeZoneIdentifier: String
    var buckets: [MessagesIPCActivityRange]
    var matchingChatCount: Int
    var overallActivity: MessagesIPCOverallActivity?
    var chats: [MessagesIPCChatActivity]?
    var participants: [MessagesIPCParticipantReference]?
    var nextCursor: String?
}

struct MessagesIPCCountActivityRequest: Codable, Equatable, Sendable {
    var fromDate: Date?
    var toDate: Date?
    var interval: MessagesIPCActivityInterval
    var chatType: MessagesIPCActivityChatType?
    var chatGUIDs: [String]
    var breakdown: MessagesIPCActivityBreakdown
    var rankBy: MessagesIPCActivityRank
    var chatLimit: Int
    var cursor: String?
}

struct MessagesIPCImage: Codable, Equatable {
    var data: Data
    var mimeType: String
    var chatGUID: String
    var chatDisplayName: String
}

struct MessagesIPCReadImageRequest: Codable, Equatable, Sendable {
    var id: String
}

enum MessagesIPCRoute: String, CaseIterable {
    case findChats = "ComputerUseIPCMessagesFindChatsRequest"
    case searchChats = "ComputerUseIPCMessagesSearchChatsRequest"
    case readMessages = "ComputerUseIPCMessagesReadMessagesRequest"
    case searchMessages = "ComputerUseIPCMessagesSearchMessagesRequest"
    case prepareSend = "ComputerUseIPCMessagesPrepareSendRequest"
    case commitSend = "ComputerUseIPCMessagesCommitSendRequest"
    case countActivity = "ComputerUseIPCMessagesCountActivityRequest"
    case readImage = "ComputerUseIPCMessagesReadImageRequest"
}

