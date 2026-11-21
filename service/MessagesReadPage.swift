import Foundation

enum MessagesReadPage {
    struct Item {
        var chatGUID: String
        var chatDisplayName: String
        var sender: MessagesIPCParticipant?
        var isFromMe: Bool
        var body: String?
        var date: Date
        var attachments: [MessagesIPCMessageAttachment]
        var isUnread: Bool?
    }

    static func make(_ request: MessagesIPCReadMessagesRequest, database: () throws -> URL,
                     contactName: (String) throws -> String?) throws -> MessagesIPCMessagesPage {
        guard let query = try MessagesReadValidation.readMessages(request) else {
            return assemble([], cursor: nil)
        }
        let filters = MessagesReadFilters(chatGUID: query.chatGUID, fromDate: query.fromDate,
            toDate: query.toDate, unreadOnly: query.unreadOnly)
        let cursor = try query.cursor.map { try MessagesPaging.read($0, filters: filters) }
        let store = try MessagesAttachmentStore(file: database())
        let bound = try cursor?.messageRowIDUpperBound ?? store.messageRowIDUpperBound()
        let rows = try store.readRows(filters, upperBound: bound, before: cursor?.lastReturnedSortKey, limit: query.limit + 1)
        let page = rows.prefix(query.limit)
        guard let last = page.last else { return assemble([], cursor: nil) }
        let next: String?
        if rows.count > query.limit {
            next = try MessagesPaging.ReadCursor(lastReturnedSortKey: last.sortKey,
                messageRowIDUpperBound: bound, state: nil, fingerprint: MessagesPaging.fingerprint(filters),
                formatVersion: 1, tool: "read_messages").encoded()
        } else {
            next = nil
        }
        return try enrich(page.map(\.message), cursor: next, store: store, contactName: contactName)
    }

    static func search(_ request: MessagesIPCSearchMessagesRequest, database: () throws -> URL,
                       aliases: (String) throws -> [String], contactName: (String) throws -> String?) throws -> MessagesIPCMessagesPage {
        guard let query = try MessagesReadValidation.searchMessages(request) else {
            return assemble([], cursor: nil)
        }
        let filters = MessagesSearchFilters(text: query.text, chatGUIDs: query.chatGUIDs,
            participants: query.participants, exactParticipants: query.exactParticipants,
            fromDate: query.fromDate, toDate: query.toDate)
        let groups = try MessagesChatDiscovery.resolveParticipants(query.participants, aliases: aliases)
        let cursor = try query.cursor.map { try MessagesPaging.search($0, filters: filters) }
        let store = try MessagesAttachmentStore(file: database(), timeoutSeconds: 7)
        let bound = try cursor?.messageRowIDUpperBound ?? store.messageRowIDUpperBound()
        let rows = try store.searchRows(filters, aliases: groups, upperBound: bound,
            before: cursor?.lastReturnedSortKey, limit: query.limit + 1)
        let page = rows.prefix(query.limit)
        guard let last = page.last else { return assemble([], cursor: nil) }
        let next: String?
        if rows.count > query.limit {
            next = try MessagesPaging.SearchCursor(lastReturnedSortKey: last.sortKey,
                messageRowIDUpperBound: bound, state: nil, fingerprint: MessagesPaging.fingerprint(filters),
                formatVersion: 1, tool: "search_messages").encoded()
        } else {
            next = nil
        }
        return try enrich(page.map(\.message), cursor: next, store: store, contactName: contactName)
    }

    private static func enrich(_ messages: [MessagesAttachmentStore.Message], cursor: String?,
                               store: MessagesAttachmentStore, contactName: (String) throws -> String?) throws -> MessagesIPCMessagesPage {
        var chats = [String: (id: Int64, name: String)]()
        for message in messages where chats[message.chatGUID] == nil {
            guard let chat = try store.chatMetadata(message.chatGUID) else {
                throw MessagesReadValidationError.invalid("one or more message chats were not found")
            }
            let name = try store.chatDisplayName(chat.displayName, rowID: chat.rowID, contactName: contactName)
            chats[chat.guid] = (chat.rowID, name)
        }
        let messageIDs = Set(messages.map(\.rowID))
        let senderIDs = Set(messages.lazy.filter { !$0.isFromMe }.map(\.senderHandleRowID))
        let senders = try store.senders(senderIDs).mapValues { participant in
            var result = participant
            result.name = try contactName(participant.handle)
            return result
        }
        let attachments = try store.attachments(for: messageIDs)
        let items = try messages.map { message -> Item in
            guard let chat = chats[message.chatGUID] else {
                throw MessagesReadValidationError.invalid("one or more message chats were not found")
            }
            let files = try (attachments[message.rowID] ?? []).map { attachment in
                guard let id = MessagesAttachmentID(attachmentRowID: attachment.rowID, chatRowID: chat.id) else {
                    throw MessagesReadValidationError.invalid("image attachment id is invalid")
                }
                return MessagesIPCMessageAttachment(id: id.encoded, filename: attachment.filename,
                    mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes)
            }
            return Item(chatGUID: message.chatGUID, chatDisplayName: chat.name, sender: senders[message.senderHandleRowID],
                isFromMe: message.isFromMe, body: message.body, date: message.date,
                attachments: files, isUnread: message.isUnread)
        }
        return assemble(items, cursor: cursor)
    }

    static func assemble(_ items: [Item], cursor: String?) -> MessagesIPCMessagesPage {
        var chats = [MessagesIPCChatReference]()
        var senders = MessagesParticipantReferences()
        var chatRefs = [String: String]()
        let messages = items.map { item -> MessagesIPCMessage in
            let chatRef: String
            if let existing = chatRefs[item.chatGUID] {
                chatRef = existing
            } else {
                chatRef = String(chats.count)
                chatRefs[item.chatGUID] = chatRef
                chats.append(.init(localRef: chatRef, guid: item.chatGUID, displayName: item.chatDisplayName))
            }
            let senderRef: String
            if item.isFromMe {
                senderRef = "me"
            } else if let sender = item.sender {
                senderRef = senders.add(sender)
            } else {
                senderRef = "unknown"
            }
            return .init(chat: chatRef, sender: senderRef, body: item.body, date: item.date,
                attachments: item.attachments.isEmpty ? nil : item.attachments, isUnread: item.isUnread)
        }
        return .init(chats: chats, senders: senders.values, messages: messages, nextCursor: cursor)
    }
}
