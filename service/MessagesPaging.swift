import CryptoKit
import Foundation

struct MessagesReadFilters: Codable, Equatable {
    var chatGUID: String
    var fromDate: Date?
    var toDate: Date?
    var unreadOnly: Bool
}

struct MessagesSearchFilters: Codable, Equatable {
    var text: String
    var chatGUIDs: [String]
    var participants: [String]
    var exactParticipants: Bool
    var fromDate: Date?
    var toDate: Date?
}

struct MessagesReadSortKey: Codable, Equatable {
    var dateNanoseconds: Int64
    var rowID: Int
}

struct MessagesSearchSortKey: Codable, Equatable {
    var dateNanoseconds: Int64
    var rowID: Int
    var chatRowID: Int
}

struct MessagesEmptyCursorState: Codable, Equatable {}

struct MessagesActivityFilters: Codable, Equatable {
    var fromDate: Date?
    var toDate: Date?
    var interval: MessagesIPCActivityInterval
    var chatType: MessagesIPCActivityChatType?
    var chatGUIDs: [String]
    var breakdown: MessagesIPCActivityBreakdown
    var rankBy: MessagesIPCActivityRank
}

struct MessagesActivitySortKey: Codable, Equatable {
    var count: Int
    var chatRowID: Int
}

struct MessagesActivityCursorState: Codable, Equatable {
    var range: MessagesIPCActivityRange
    var timeZoneIdentifier: String

    private enum CodingKeys: String, CodingKey {
        case range = "r"
        case timeZoneIdentifier = "z"
    }
}

struct MessagesActivityFingerprint: Codable {
    var filters: MessagesActivityFilters
    var range: MessagesIPCActivityRange
    var timeZoneIdentifier: String

    init(_ filters: MessagesActivityFilters, _ state: MessagesActivityCursorState) {
        self.filters = filters
        range = state.range
        timeZoneIdentifier = state.timeZoneIdentifier
    }
}

struct MessagesCursor<SortKey: Codable & Equatable, State: Codable & Equatable>: Codable, Equatable {
    var lastReturnedSortKey: SortKey
    var messageRowIDUpperBound: Int
    var state: State?
    var fingerprint: Data
    var formatVersion: Int
    var tool: String

    private enum CodingKeys: String, CodingKey {
        case lastReturnedSortKey = "k"
        case messageRowIDUpperBound = "b"
        case state = "s"
        case fingerprint = "f"
        case formatVersion = "v"
        case tool = "t"
    }

    func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }
}

enum MessagesPaging {
    typealias ReadCursor = MessagesCursor<MessagesReadSortKey, MessagesEmptyCursorState>
    typealias SearchCursor = MessagesCursor<MessagesSearchSortKey, MessagesEmptyCursorState>
    typealias ActivityCursor = MessagesCursor<MessagesActivitySortKey, MessagesActivityCursorState>

    enum CursorError: Error {
        case malformed, mismatchedFingerprint, mismatchedTool, unsupportedVersion

        func message(tool: String) -> String {
            switch self {
            case .malformed: return "cursor is malformed; use next_cursor returned by \(tool)"
            case .mismatchedFingerprint: return "cursor does not match the current \(tool) filters"
            case .mismatchedTool: return "cursor was created by a different Messages tool; use next_cursor returned by \(tool)"
            case .unsupportedVersion: return "cursor version is unsupported; call \(tool) again without a cursor"
            }
        }
    }

    static func fingerprint(_ filters: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(filters)))
    }

    static func read(_ input: String, filters: MessagesReadFilters) throws -> ReadCursor {
        let cursor = try decode(ReadCursor.self, input: input, tool: "read_messages", filters: filters)
        guard valid(rowID: cursor.lastReturnedSortKey.rowID, upperBound: cursor.messageRowIDUpperBound) else {
            throw CursorError.malformed
        }
        return cursor
    }

    static func search(_ input: String, filters: MessagesSearchFilters) throws -> SearchCursor {
        let cursor = try decode(SearchCursor.self, input: input, tool: "search_messages", filters: filters)
        guard valid(rowID: cursor.lastReturnedSortKey.rowID, upperBound: cursor.messageRowIDUpperBound),
              cursor.lastReturnedSortKey.chatRowID >= 1 else { throw CursorError.malformed }
        return cursor
    }

    // Changing limit does not change the fingerprint.
    static func decode<Key, State>(
        _ type: MessagesCursor<Key, State>.Type, input: String, tool: String, filters: some Encodable
    ) throws -> MessagesCursor<Key, State> {
        let cursor = try envelope(type, input: input, tool: tool)
        guard try cursor.fingerprint == fingerprint(filters) else { throw CursorError.mismatchedFingerprint }
        return cursor
    }

    static func activity(_ input: String, filters: MessagesActivityFilters) throws -> ActivityCursor {
        let cursor = try envelope(ActivityCursor.self, input: input, tool: "count_message_activity")
        guard let state = cursor.state else { throw CursorError.malformed }
        guard try cursor.fingerprint == fingerprint(MessagesActivityFingerprint(filters, state)) else {
            throw CursorError.mismatchedFingerprint
        }
        guard cursor.lastReturnedSortKey.count >= 0, cursor.lastReturnedSortKey.chatRowID >= 1,
              cursor.messageRowIDUpperBound >= 1, state.range.from < state.range.to,
              TimeZone(identifier: state.timeZoneIdentifier) != nil else { throw CursorError.malformed }
        return cursor
    }

    private static func envelope<Key, State>(
        _ type: MessagesCursor<Key, State>.Type, input: String, tool: String
    ) throws -> MessagesCursor<Key, State> {
        guard let data = Data(base64Encoded: input),
              let cursor = try? JSONDecoder().decode(type, from: data) else { throw CursorError.malformed }
        guard cursor.formatVersion == 1 else { throw CursorError.unsupportedVersion }
        guard cursor.tool == tool else { throw CursorError.mismatchedTool }
        return cursor
    }

    private static func valid(rowID: Int, upperBound: Int) -> Bool {
        rowID >= 1 && rowID <= upperBound
    }
}
