import Foundation

enum MessagesChatDiscovery {
    static func search(_ request: MessagesIPCSearchChatsRequest, database: () throws -> URL,
                       aliases: (String) throws -> [String], contactName: (String) throws -> String?) throws -> MessagesIPCChatSearchPage {
        guard let query = MessagesReadValidation.searchChats(request) else {
            return .init(chats: [], hasMore: false)
        }
        let preferred = query.query.isEmpty ? [] : try aliases(query.query)
        let store = try MessagesAttachmentStore(file: database())
        let rows = try store.searchChats(query, preferredAliases: preferred)
        let chats = try rows.prefix(query.limit).map { row in
            try MessagesIPCChatMetadata(guid: row.guid,
                displayName: store.chatDisplayName(row.displayName, rowID: Int64(row.rowID), contactName: contactName))
        }
        return .init(chats: chats, hasMore: rows.count > query.limit)
    }

    static func find(_ request: MessagesIPCFindChatsRequest, database: () throws -> URL,
                     aliases: (String) throws -> [String], contactName: (String) throws -> String?) throws -> MessagesIPCChatsPage {
        guard let query = try MessagesReadValidation.findChats(request) else {
            return .init(chats: [], participants: [], hasMore: false)
        }
        let groups = try resolveParticipants(query.participants, aliases: aliases)
        let store = try MessagesAttachmentStore(file: database())
        let rows = try store.findChats(query, aliases: groups)
        var references = MessagesParticipantReferences()
        let chats = try rows.prefix(query.limit).map { row in
            let participants = try store.chatParticipants(Int64(row.rowID)).map { participant in
                var value = participant
                value.name = try contactName(value.handle)
                return value
            }
            let name = row.displayName.isEmpty ? participants.map { $0.name ?? $0.handle }.joined(separator: ", ") : row.displayName
            return MessagesIPCChat(guid: row.guid, displayName: name, service: row.service,
                lastMessageDate: row.lastMessageDate, participants: participants.map { references.add($0) },
                unreadCount: row.unreadCount)
        }
        return .init(chats: chats, participants: references.values, hasMore: rows.count > query.limit)
    }

    static func resolveParticipants(_ participants: [String], aliases: (String) throws -> [String]) throws -> [[String]] {
        try participants.map { participant in
            let values = try aliases(participant)
            guard !values.isEmpty else {
                throw MessagesReadValidationError.invalid("participant \(participant) was not found; use an exact phone number or email address")
            }
            return values
        }
    }

    static func searchAlias(_ value: String) -> String {
        if value.contains("@") { return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let stripped = value.replacingOccurrences(of: #"[\s()\-]"#, with: "", options: .regularExpression)
        return stripped.hasPrefix("0") ? String(stripped.dropFirst()) : stripped
    }

    static func exactAlias(_ value: String) -> String {
        let normalized = searchAlias(value)
        return normalized.hasPrefix("+") ? String(normalized.dropFirst()) : normalized
    }
}

struct MessagesParticipantReferences {
    private struct Identity: Hashable {
        let handle: String
        let service: String?
    }

    private var ids = [Identity: String]()
    private(set) var values = [MessagesIPCParticipantReference]()

    mutating func add(_ participant: MessagesIPCParticipant) -> String {
        let identity = Identity(handle: participant.handle, service: participant.service?.rawValue)
        if let existing = ids[identity] { return existing }
        let id = String(values.count)
        ids[identity] = id
        values.append(.init(localRef: id, handle: participant.handle, name: participant.name, service: participant.service))
        return id
    }
}
