import Foundation
import SQLite3

final class MessagesAttachmentStore {
    struct DatabaseError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var isTimeout: Bool { code == SQLITE_INTERRUPT }
        var description: String { "SQLite \(code): \(message)" }
    }

    struct Location: Equatable {
        var path: String
        var chatRowID: Int64
        var chatGUID: String
        var chatDisplayName: String
    }

    struct Message: Codable, Equatable {
        var rowID: Int
        var guid: String
        var chatGUID: String
        var body: String?
        var date: Date
        var isFromMe: Bool
        var senderHandleRowID: Int
        var isUnread: Bool?
    }

    struct PageItem: Codable, Equatable {
        var message: Message
        var sortKey: MessagesReadSortKey
    }

    struct SearchPageItem {
        var message: Message
        var sortKey: MessagesSearchSortKey
    }

    struct Chat {
        let rowID: Int64
        let guid: String
        let displayName: String
    }

    struct Attachment {
        let rowID: Int64
        let filename: String?
        let mimeType: String?
        let sizeBytes: Int?
    }

    struct DiscoveredChat: Equatable {
        let rowID: Int
        let guid: String
        let displayName: String
        let service: MessagesIPCService
        let lastMessageDate: Date
        let unreadCount: Int?
    }

    private enum Binding {
        case text(String), integer(Int64)

        func bind(to statement: OpaquePointer, index: Int32) -> Int32 {
            switch self {
            case .text(let value):
                return sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), transient)
            case .integer(let value):
                return sqlite3_bind_int64(statement, index, value)
            }
        }
    }

    private struct Bindings {
        var values = [Binding]()

        mutating func add(_ value: Binding) -> String {
            values.append(value)
            return "?\(values.count)"
        }
    }

    private let database: OpaquePointer
    private let hasHiddenAttachments: Bool
    private let deadline: Deadline
    private let snapshotDirectory: URL?
    private final class Deadline {
        let end: DispatchTime

        init(seconds: Int) {
            end = DispatchTime.now() + .seconds(seconds)
        }
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let unreadPredicate = """
        message.item_type = 0 AND message.is_read = 0 AND message.is_from_me = 0
        AND message.is_finished = 1 AND message.is_system_message = 0
        """

    init(file: URL, timeoutSeconds: Int = 5) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY | SQLITE_OPEN_URI
        let code = sqlite3_open_v2(":memory:", &opened, flags, nil)
        guard code == SQLITE_OK, let database = opened else {
            let error = Self.error(code, opened)
            sqlite3_close_v2(opened)
            throw error
        }
        let deadline = Deadline(seconds: timeoutSeconds)
        sqlite3_progress_handler(database, 500, { context in
            guard let context else { return 0 }
            let deadline = Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue()
            return DispatchTime.now() >= deadline.end ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        var snapshot: URL?
        do {
            do {
                try Self.attach(file, readOnly: true, to: database)
            } catch let error as DatabaseError where error.code & 0xff == SQLITE_BUSY {
                let copy = try Self.makeSnapshot(of: file)
                snapshot = copy.deletingLastPathComponent()
                // SQLite can replay a hot journal on the owned copy.
                try Self.attach(copy, readOnly: false, to: database)
            }
            try Self.check(sqlite3_create_function_v2(database, "extract_message", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                nil, Self.extractMessage, nil, nil, nil), database)
            let schema = try Self.prepare("PRAGMA messages.table_info(attachment)", database)
            defer { sqlite3_finalize(schema) }
            var hidden = false
            var row = sqlite3_step(schema)
            while row == SQLITE_ROW {
                if Self.text(schema, 1) == "hide_attachment" { hidden = true }
                row = sqlite3_step(schema)
            }
            try Self.check(row, database, expected: SQLITE_DONE)
            self.database = database
            self.deadline = deadline
            snapshotDirectory = snapshot
            hasHiddenAttachments = hidden
        } catch {
            sqlite3_close_v2(database)
            if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(database)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
    }

    private static func attach(_ file: URL, readOnly: Bool, to database: OpaquePointer) throws {
        let statement = try prepare("ATTACH DATABASE ? AS messages", database)
        defer { sqlite3_finalize(statement) }
        let uri = file.absoluteString + (readOnly ? "?mode=ro" : "?mode=rw")
        try check(sqlite3_bind_text(statement, 1, uri, -1, transient), database)
        try check(sqlite3_step(statement), database, expected: SQLITE_DONE)
    }

    private static func makeSnapshot(of file: URL) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("database-snapshot-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        func copyRegularFile(_ source: URL, to destination: URL) throws {
            try manager.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else {
                throw CocoaError(.fileReadUnknown)
            }
        }
        do {
            let copy = directory.appendingPathComponent(file.lastPathComponent)
            try copyRegularFile(file, to: copy)
            for suffix in ["-wal", "-journal"] {
                let sidecar = URL(fileURLWithPath: file.path + suffix)
                do {
                    try copyRegularFile(sidecar, to: directory.appendingPathComponent(sidecar.lastPathComponent))
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // The journal may disappear while the writer commits.
                }
            }
            return copy
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func locate(_ id: MessagesAttachmentID) throws -> Location? {
        let hiddenFilter = hasHiddenAttachments ? "AND attachment.hide_attachment = 0" : ""
        let statement = try Self.prepare("""
            SELECT attachment.filename, chat.guid, chat.display_name
            FROM messages.attachment attachment
            JOIN messages.message_attachment_join maj ON maj.attachment_id = attachment.ROWID
            JOIN messages.message message ON message.ROWID = maj.message_id
            JOIN messages.chat_message_join cmj ON cmj.message_id = message.ROWID
            JOIN messages.chat chat ON chat.ROWID = cmj.chat_id
            WHERE attachment.ROWID = ? AND chat.ROWID = ? AND length(attachment.filename) > 0
            \(hiddenFilter)
            LIMIT 1
            """, database)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_bind_int64(statement, 1, id.attachmentRowID), database)
        try Self.check(sqlite3_bind_int64(statement, 2, id.chatRowID), database)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        try Self.check(result, database, expected: SQLITE_ROW)
        guard let path = Self.text(statement, 0), let guid = Self.text(statement, 1) else { return nil }
        return Location(path: path, chatRowID: id.chatRowID, chatGUID: guid,
                        chatDisplayName: Self.text(statement, 2) ?? "")
    }

    func messageRowIDUpperBound() throws -> Int {
        let statement = try Self.prepare("SELECT COALESCE(MAX(ROWID), 0) FROM messages.message", database)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_step(statement), database, expected: SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    func participants(in chatRowID: Int64) throws -> [String] {
        try chatParticipants(chatRowID, includeService: false).map(\.handle)
    }

    func chatParticipants(_ chatRowID: Int64, includeService: Bool = true) throws -> [MessagesIPCParticipant] {
        let statement = try Self.prepare("""
            SELECT handle.id, \(includeService ? "handle.service" : "NULL")
            FROM messages.chat_handle_join chj
            JOIN messages.handle handle ON chj.handle_id = handle.ROWID
            WHERE chj.chat_id = ?
            ORDER BY handle.ROWID
            """, database)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_bind_int64(statement, 1, chatRowID), database)
        var result = [MessagesIPCParticipant]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try Self.check(code, database, expected: SQLITE_ROW)
            result.append(.init(handle: Self.text(statement, 0) ?? "",
                service: Self.text(statement, 1).map(MessagesIPCService.init(raw:))))
        }
    }

    func findChats(_ query: MessagesIPCFindChatsRequest, aliases: [[String]]) throws -> [DiscoveredChat] {
        var bindings = Bindings()
        guard var conditions = try participantConditions(aliases, exact: query.exactParticipants, bindings: &bindings)
        else { return [] }
        if let name = query.name, !name.isEmpty {
            conditions.append("chat.display_name LIKE \(bindings.add(.text("%" + name + "%")))")
        }
        return try discoverChats(conditions: conditions, priority: "0", from: query.fromDate, to: query.toDate,
            unreadOnly: query.unreadOnly, countUnread: true, limit: query.limit + 1, bindings: &bindings)
    }

    private func participantConditions(_ aliases: [[String]], exact: Bool, bindings: inout Bindings) throws -> [String]? {
        var conditions = [String]()
        var matching = Set<Int>()
        for group in aliases {
            let handles = try matchingHandles(group)
            let exactAliases = Set(group.map(MessagesChatDiscovery.exactAlias))
            let ids = handles.compactMap { rowID, handle in
                !exact || exactAliases.contains(MessagesChatDiscovery.exactAlias(handle)) ? rowID : nil
            }
            guard !ids.isEmpty else { return nil }
            matching.formUnion(ids)
            let slots = ids.map { bindings.add(.integer(Int64($0))) }.joined(separator: ", ")
            let candidates = """
                FROM messages.chat_handle_join chj
                WHERE chj.chat_id = chat.ROWID AND chj.handle_id IN (\(slots))
                """
            conditions.append(exact ? "(SELECT COUNT(DISTINCT chj.handle_id) \(candidates)) = 1"
                : "EXISTS (SELECT 1 \(candidates))")
        }
        if exact {
            guard !matching.isEmpty else { return nil }
            let allowed = matching.sorted().map { bindings.add(.integer(Int64($0))) }.joined(separator: ", ")
            conditions.append("""
                NOT EXISTS (SELECT 1 FROM messages.chat_handle_join chj
                    WHERE chj.chat_id = chat.ROWID AND chj.handle_id NOT IN (\(allowed)))
                """)
            let count = bindings.add(.integer(Int64(aliases.count)))
            conditions.append("""
                (SELECT COUNT(DISTINCT chj.handle_id) FROM messages.chat_handle_join chj
                    WHERE chj.chat_id = chat.ROWID) = \(count)
                """)
        }
        return conditions
    }

    func searchChats(_ query: MessagesIPCSearchChatsRequest, preferredAliases: [String]) throws -> [DiscoveredChat] {
        var bindings = Bindings()
        var conditions = [String]()
        var priority = "0"
        if !query.query.isEmpty {
            let preferred = try matchingHandles(preferredAliases)
            let original = bindings.add(.text("%" + Self.escapeLike(query.query) + "%"))
            let normalized = MessagesChatDiscovery.searchAlias(query.query)
            let patterns = normalized.isEmpty || normalized == query.query ? [original]
                : [original, bindings.add(.text("%" + Self.escapeLike(normalized) + "%"))]
            let matchName = "chat.display_name LIKE \(original) ESCAPE '\\'"
            var handleMatches = patterns.flatMap { pattern in
                ["handle.id LIKE \(pattern) ESCAPE '\\'", "handle.uncanonicalized_id LIKE \(pattern) ESCAPE '\\'"]
            }
            var preferredMatches = [matchName]
            if !preferred.isEmpty {
                let slots = preferred.keys.sorted().map { bindings.add(.integer(Int64($0))) }.joined(separator: ", ")
                handleMatches.append("handle.ROWID IN (\(slots))")
                preferredMatches.append("""
                    chat.ROWID IN (SELECT chat_id FROM messages.chat_handle_join WHERE handle_id IN (\(slots)))
                    """)
            }
            conditions.append("""
                (\(matchName) OR chat.ROWID IN (
                    SELECT chj.chat_id FROM messages.chat_handle_join chj
                    JOIN messages.handle handle ON handle.ROWID = chj.handle_id
                    WHERE \(handleMatches.joined(separator: " OR "))
                ))
                """)
            priority = "CASE WHEN \(preferredMatches.joined(separator: " OR ")) THEN 0 ELSE 1 END"
        }
        return try discoverChats(conditions: conditions, priority: priority, from: nil, to: nil,
            unreadOnly: false, countUnread: false, limit: query.limit + 1, bindings: &bindings)
    }

    private func matchingHandles(_ aliases: [String]) throws -> [Int: String] {
        let normalized = Set(aliases.map(MessagesChatDiscovery.searchAlias)).sorted()
        guard !normalized.isEmpty else { return [:] }
        var bindings = Bindings()
        let slots = normalized.map { bindings.add(.text($0)) }.joined(separator: ", ")
        var conditions = ["lower(id) IN (\(slots))", "lower(uncanonicalized_id) IN (\(slots))"]
        for alias in normalized where !alias.contains("@") {
            conditions.append("lower(id) LIKE \(bindings.add(.text("%" + Self.escapeLike(alias)))) ESCAPE '\\'")
        }
        let statement = try boundStatement("""
            SELECT ROWID, id FROM messages.handle WHERE \(conditions.joined(separator: " OR "))
            """, bindings)
        defer { sqlite3_finalize(statement) }
        var result = [Int: String]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try Self.check(code, database, expected: SQLITE_ROW)
            result[Int(sqlite3_column_int64(statement, 0))] = Self.text(statement, 1) ?? ""
        }
    }

    private func discoverChats(conditions: [String], priority: String, from: Date?, to: Date?, unreadOnly: Bool,
                               countUnread: Bool, limit: Int, bindings: inout Bindings) throws -> [DiscoveredChat] {
        let start = from.flatMap { Int64(exactly: $0.timeIntervalSinceReferenceDate * 1_000_000_000) }
            .map { bindings.add(.integer($0)) }
        let end = to.flatMap { Int64(exactly: $0.timeIntervalSinceReferenceDate * 1_000_000_000) }
            .map { bindings.add(.integer($0)) }
        func dateRange(_ column: String) -> String {
            let lower = start.map { "AND \(column) >= \($0)" } ?? ""
            let upper = end.map { "AND \(column) < \($0)" } ?? ""
            return "\(lower) \(upper)"
        }
        func unread(_ chatID: String) -> String {
            """
            SELECT COUNT(*) FROM messages.chat_message_join unread
            JOIN messages.message message ON message.ROWID = unread.message_id
            WHERE unread.chat_id = \(chatID) AND (\(Self.unreadPredicate))
            """
        }
        let filter = (conditions + (unreadOnly ? ["(\(unread("chat.ROWID"))) > 0"] : [])).joined(separator: " AND ")
        let whereClause = filter.isEmpty ? "" : "WHERE \(filter)"
        let source = filter.isEmpty ? """
            (SELECT DISTINCT chat_id FROM messages.chat_message_join) active_chats
            CROSS JOIN messages.chat chat ON chat.ROWID = active_chats.chat_id
            """ : "messages.chat chat"
        let unreadCount = countUnread ? "(\(unread("chat.row_id")))" : "NULL"
        let maximum = bindings.add(.integer(Int64(limit)))
        let statement = try boundStatement("""
            WITH candidate_dates AS MATERIALIZED (
                SELECT chat.ROWID AS row_id, chat.guid, chat.display_name, chat.service_name,
                    \(priority) AS match_priority,
                    (SELECT MAX(cmj.message_date) FROM messages.chat_message_join cmj
                        JOIN messages.message message ON message.ROWID = cmj.message_id
                        WHERE cmj.chat_id = chat.ROWID AND cmj.message_date != 0 \(dateRange("cmj.message_date"))) AS indexed_date,
                    (SELECT MAX(message.date) FROM messages.chat_message_join cmj
                        JOIN messages.message message ON message.ROWID = cmj.message_id
                        WHERE cmj.chat_id = chat.ROWID AND (cmj.message_date = 0 OR cmj.message_date IS NULL)
                        \(dateRange("message.date"))) AS fallback_date
                FROM \(source) \(whereClause)
            ), selected AS (
                SELECT *, CASE
                    WHEN indexed_date IS NULL THEN fallback_date
                    WHEN fallback_date IS NULL THEN indexed_date
                    ELSE MAX(indexed_date, fallback_date) END AS last_date
                FROM candidate_dates
                WHERE indexed_date IS NOT NULL OR fallback_date IS NOT NULL
                ORDER BY match_priority, last_date DESC, row_id DESC LIMIT \(maximum)
            )
            SELECT chat.row_id, chat.guid, chat.display_name, chat.service_name,
                strftime('%s', round(last_date / 1000000000) + 978307200, 'unixepoch'),
                \(unreadCount)
            FROM selected chat ORDER BY match_priority, last_date DESC, row_id DESC
            """, bindings)
        defer { sqlite3_finalize(statement) }
        var result = [DiscoveredChat]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try Self.check(code, database, expected: SQLITE_ROW)
            guard let seconds = Self.text(statement, 4).flatMap(Double.init) else { throw CocoaError(.formatting) }
            let unreadCount = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 5))
            result.append(.init(rowID: Int(sqlite3_column_int64(statement, 0)), guid: Self.text(statement, 1) ?? "",
                displayName: Self.text(statement, 2) ?? "", service: .init(raw: Self.text(statement, 3) ?? ""),
                lastMessageDate: Date(timeIntervalSince1970: seconds), unreadCount: unreadCount))
        }
    }

    private func boundStatement(_ sql: String, _ bindings: Bindings) throws -> OpaquePointer {
        let statement = try Self.prepare(sql, database)
        do {
            for (index, binding) in bindings.values.enumerated() {
                try Self.check(binding.bind(to: statement, index: Int32(index + 1)), database)
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func chatDisplayName(_ name: String, rowID: Int64, contactName: (String) throws -> String?) throws -> String {
        guard name.isEmpty else { return name }
        return try participants(in: rowID).map { try contactName($0) ?? $0 }.joined(separator: ", ")
    }

    func chatMetadata(_ guid: String) throws -> Chat? {
        let statement = try Self.prepare("""
            SELECT ROWID, guid, display_name FROM messages.chat WHERE guid = ? ORDER BY ROWID
            """, database)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_bind_text(statement, 1, guid, Int32(guid.utf8.count), Self.transient), database)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        try Self.check(code, database, expected: SQLITE_ROW)
        let result = Chat(rowID: sqlite3_column_int64(statement, 0),
            guid: Self.text(statement, 1) ?? "", displayName: Self.text(statement, 2) ?? "")
        let next = sqlite3_step(statement)
        if next == SQLITE_ROW { return nil }
        try Self.check(next, database, expected: SQLITE_DONE)
        return result
    }

    func senders(_ rowIDs: Set<Int>) throws -> [Int: MessagesIPCParticipant] {
        guard !rowIDs.isEmpty else { return [:] }
        let statement = try Self.prepare("""
            SELECT ROWID, id, service FROM messages.handle
            WHERE ROWID IN (\(Self.placeholders(rowIDs.count))) ORDER BY ROWID
            """, database)
        defer { sqlite3_finalize(statement) }
        try bindRowIDs(rowIDs, to: statement)
        var result = [Int: MessagesIPCParticipant]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try Self.check(code, database, expected: SQLITE_ROW)
            let rowID = Int(sqlite3_column_int64(statement, 0))
            result[rowID] = .init(handle: Self.text(statement, 1) ?? "",
                service: Self.text(statement, 2).map(MessagesIPCService.init(raw:)))
        }
    }

    func attachments(for rowIDs: Set<Int>) throws -> [Int: [Attachment]] {
        guard !rowIDs.isEmpty else { return [:] }
        let hiddenFilter = hasHiddenAttachments ? "AND attachment.hide_attachment = 0" : ""
        let statement = try Self.prepare("""
            SELECT maj.message_id, attachment.ROWID, attachment.filename,
                attachment.transfer_name, attachment.mime_type, attachment.total_bytes
            FROM messages.message_attachment_join maj
            JOIN messages.attachment attachment ON attachment.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(Self.placeholders(rowIDs.count))) \(hiddenFilter)
            ORDER BY maj.message_id, attachment.ROWID
            """, database)
        defer { sqlite3_finalize(statement) }
        try bindRowIDs(rowIDs, to: statement)
        var result = [Int: [Attachment]]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try Self.check(code, database, expected: SQLITE_ROW)
            let rowID = Int(sqlite3_column_int64(statement, 0))
            let names = [Self.text(statement, 3), Self.text(statement, 2)].compactMap { $0 }
            let filename = names.lazy.map { ($0 as NSString).lastPathComponent }.first { !$0.isEmpty }
            let mime = Self.text(statement, 4).flatMap { $0.isEmpty ? nil : $0 }
            let bytes = sqlite3_column_int64(statement, 5)
            let size = sqlite3_column_type(statement, 5) == SQLITE_NULL || bytes < 0 ? nil : Int(bytes)
            result[rowID, default: []].append(.init(rowID: sqlite3_column_int64(statement, 1),
                filename: filename, mimeType: mime, sizeBytes: size))
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func bindRowIDs(_ rowIDs: Set<Int>, to statement: OpaquePointer) throws {
        for (index, rowID) in rowIDs.enumerated() {
            try Self.check(sqlite3_bind_int64(statement, Int32(index + 1), Int64(rowID)), database)
        }
    }

    func readRows(_ filters: MessagesReadFilters, upperBound: Int, before: MessagesReadSortKey?, limit: Int) throws -> [PageItem] {
        let from = filters.fromDate.flatMap { Int64(exactly: $0.timeIntervalSinceReferenceDate * 1_000_000_000) }
        let to = filters.toDate.flatMap { Int64(exactly: $0.timeIntervalSinceReferenceDate * 1_000_000_000) }

        func candidates(date: String, joinDateFilter: String) -> String {
            let start = from == nil ? "" : "AND \(date) >= ?4"
            let end = to == nil ? "" : "AND \(date) < ?5"
            let cursor = before == nil ? "" : "AND (\(date) < ?6 OR (\(date) = ?6 AND cmj.message_id < ?7))"
            let unread = filters.unreadOnly ? "AND (\(Self.unreadPredicate))" : ""
            return """
                SELECT cmj.message_id AS row_id, chat.guid AS chat_guid, \(date) AS sort_date
                FROM messages.chat chat
                JOIN messages.chat_message_join cmj ON cmj.chat_id = chat.ROWID
                JOIN messages.message message ON message.ROWID = cmj.message_id
                WHERE chat.guid = ?1 AND cmj.message_id <= ?2 AND (\(joinDateFilter))
                    \(start) \(end) \(cursor) \(unread)
                ORDER BY \(date) DESC, cmj.message_id DESC LIMIT ?3
                """
        }

        let statement = try Self.prepare("""
            WITH indexed_candidates AS (
                \(candidates(date: "cmj.message_date", joinDateFilter: "cmj.message_date != 0"))
            ), zero_date_candidates AS (
                \(candidates(date: "message.date", joinDateFilter: "cmj.message_date = 0"))
            ), null_date_candidates AS (
                \(candidates(date: "message.date", joinDateFilter: "cmj.message_date IS NULL"))
            ), selected_messages AS (
                SELECT * FROM indexed_candidates
                UNION ALL SELECT * FROM zero_date_candidates
                UNION ALL SELECT * FROM null_date_candidates
                ORDER BY sort_date DESC, row_id DESC LIMIT ?3
            )
            SELECT message.ROWID, message.guid, selected_messages.chat_guid,
                COALESCE(extract_message(message.attributedBody), message.text),
                strftime('%s', round(message.date / 1000000000) + 978307200, 'unixepoch'),
                message.is_from_me, COALESCE(message.handle_id, 0),
                (\(filters.unreadOnly ? "1" : Self.unreadPredicate)), selected_messages.sort_date
            FROM selected_messages
            JOIN messages.message message ON message.ROWID = selected_messages.row_id
            ORDER BY selected_messages.sort_date DESC, selected_messages.row_id DESC
            """, database)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_bind_text(statement, 1, filters.chatGUID, Int32(filters.chatGUID.utf8.count), Self.transient), database)
        try Self.check(sqlite3_bind_int64(statement, 2, Int64(upperBound)), database)
        try Self.check(sqlite3_bind_int64(statement, 3, Int64(limit)), database)
        if let from { try Self.check(sqlite3_bind_int64(statement, 4, from), database) }
        if let to { try Self.check(sqlite3_bind_int64(statement, 5, to), database) }
        if let before {
            try Self.check(sqlite3_bind_int64(statement, 6, before.dateNanoseconds), database)
            try Self.check(sqlite3_bind_int64(statement, 7, Int64(before.rowID)), database)
        }

        var rows = [PageItem]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            try Self.check(code, database, expected: SQLITE_ROW)
            let message = try Self.message(statement)
            rows.append(.init(message: message,
                sortKey: .init(dateNanoseconds: sqlite3_column_int64(statement, 8), rowID: message.rowID)))
        }
    }

    func searchRows(_ filters: MessagesSearchFilters, aliases: [[String]], upperBound: Int,
                    before: MessagesSearchSortKey?, limit: Int) throws -> [SearchPageItem] {
        var bindings = Bindings()
        guard var conditions = try participantConditions(aliases, exact: filters.exactParticipants, bindings: &bindings)
        else { return [] }
        let pattern = bindings.add(.text("%" + Self.escapeLike(filters.text) + "%"))
        let body = "COALESCE(extract_message(message.attributedBody), message.text)"
        conditions.append("\(body) LIKE \(pattern) ESCAPE '\\' COLLATE NOCASE")
        if !filters.chatGUIDs.isEmpty {
            let slots = filters.chatGUIDs.map { bindings.add(.text($0)) }.joined(separator: ", ")
            conditions.append("chat.guid IN (\(slots))")
        }
        if try hasAssociatedMessageType() {
            conditions.append("""
                (message.associated_message_type IS NULL OR (
                    message.associated_message_type != 1000
                    AND message.associated_message_type NOT BETWEEN 2000 AND 2007
                    AND message.associated_message_type NOT BETWEEN 3000 AND 3007
                    AND message.associated_message_type != 4000
                ))
                """)
        }
        let from = filters.fromDate.flatMap { Int64(exactly: $0.timeIntervalSinceReferenceDate * 1_000_000_000) }
            .map { bindings.add(.integer($0)) }
        let to = filters.toDate.flatMap { Int64(exactly: $0.timeIntervalSinceReferenceDate * 1_000_000_000) }
            .map { bindings.add(.integer($0)) }
        let bound = bindings.add(.integer(Int64(upperBound)))
        let maximum = bindings.add(.integer(Int64(limit)))
        let cursor = before.map {
            (bindings.add(.integer($0.dateNanoseconds)), bindings.add(.integer(Int64($0.rowID))),
                bindings.add(.integer(Int64($0.chatRowID))))
        }
        func whereClause(date: String, rowID: String) -> String {
            var all = conditions
            if let from { all.append("\(date) >= \(from)") }
            if let to { all.append("\(date) < \(to)") }
            if let (dateBound, rowBound, chatBound) = cursor {
                all.append("(\(date), \(rowID), chat.ROWID) < (\(dateBound), \(rowBound), \(chatBound))")
            }
            return all.joined(separator: " AND ")
        }
        func candidates(date: String, joinDateFilter: String) -> String {
            """
            SELECT cmj.message_id AS row_id, chat.guid AS chat_guid, \(date) AS sort_date, chat.ROWID AS chat_row_id
            FROM messages.chat chat
            JOIN messages.chat_message_join cmj ON cmj.chat_id = chat.ROWID
            JOIN messages.message message ON message.ROWID = cmj.message_id
            WHERE cmj.message_id <= \(bound) AND (\(joinDateFilter))
                AND \(whereClause(date: date, rowID: "cmj.message_id"))
            ORDER BY sort_date DESC, row_id DESC, chat_row_id DESC LIMIT \(maximum)
            """
        }
        func fields(chatGUID: String, sortDate: String, chatID: String) -> String {
            """
            message.ROWID, message.guid, \(chatGUID), \(body),
            strftime('%s', round(message.date / 1000000000) + 978307200, 'unixepoch'),
            message.is_from_me, COALESCE(message.handle_id, 0),
            (\(Self.unreadPredicate)), \(sortDate), \(chatID)
            """
        }
        let sql: String
        if filters.chatGUIDs.count == 1 && (from != nil || to != nil) {
            sql = """
                WITH indexed_candidates AS (
                    \(candidates(date: "cmj.message_date", joinDateFilter: "cmj.message_date != 0"))
                ), zero_date_candidates AS (
                    \(candidates(date: "message.date", joinDateFilter: "cmj.message_date = 0"))
                ), null_date_candidates AS (
                    \(candidates(date: "message.date", joinDateFilter: "cmj.message_date IS NULL"))
                ), selected AS (
                    SELECT * FROM indexed_candidates
                    UNION ALL SELECT * FROM zero_date_candidates
                    UNION ALL SELECT * FROM null_date_candidates
                    ORDER BY sort_date DESC, row_id DESC, chat_row_id DESC LIMIT \(maximum)
                )
                SELECT \(fields(chatGUID: "selected.chat_guid", sortDate: "selected.sort_date", chatID: "selected.chat_row_id"))
                FROM selected JOIN messages.message message ON message.ROWID = selected.row_id
                ORDER BY selected.sort_date DESC, selected.row_id DESC, selected.chat_row_id DESC
                """
        } else {
            sql = """
                SELECT \(fields(chatGUID: "chat.guid", sortDate: "message.date", chatID: "chat.ROWID"))
                FROM messages.message message
                CROSS JOIN messages.chat_message_join cmj ON cmj.message_id = message.ROWID
                CROSS JOIN messages.chat chat ON chat.ROWID = cmj.chat_id
                WHERE likely(message.ROWID <= \(bound)) AND \(whereClause(date: "message.date", rowID: "message.ROWID"))
                ORDER BY message.date DESC, message.ROWID DESC, chat.ROWID DESC LIMIT \(maximum)
                """
        }
        let statement = try boundStatement(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows = [SearchPageItem]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            try Self.check(code, database, expected: SQLITE_ROW)
            let message = try Self.message(statement)
            rows.append(.init(message: message, sortKey: .init(dateNanoseconds: sqlite3_column_int64(statement, 8),
                rowID: message.rowID, chatRowID: Int(sqlite3_column_int64(statement, 9)))))
        }
    }

    private func hasAssociatedMessageType() throws -> Bool {
        let statement = try Self.prepare("""
            SELECT COUNT(*) FROM pragma_table_info('message', 'messages') WHERE lower(name) = 'associated_message_type'
            """, database)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_step(statement), database, expected: SQLITE_ROW)
        return sqlite3_column_int64(statement, 0) != 0
    }

    private static func message(_ statement: OpaquePointer) throws -> Message {
        guard let seconds = text(statement, 4).flatMap(Double.init) else { throw CocoaError(.formatting) }
        return Message(rowID: Int(sqlite3_column_int64(statement, 0)), guid: text(statement, 1) ?? "",
            chatGUID: text(statement, 2) ?? "", body: text(statement, 3),
            date: Date(timeIntervalSince1970: seconds), isFromMe: sqlite3_column_int(statement, 5) != 0,
            senderHandleRowID: Int(sqlite3_column_int64(statement, 6)),
            isUnread: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 7) != 0)
    }

    private static let extractMessage: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = {
        context, _, values in
        guard let value = values?.pointee, let pointer = sqlite3_value_blob(value) else { return }
        let input = UnsafeRawBufferPointer(start: pointer, count: Int(sqlite3_value_bytes(value)))
        guard let body = MessagesAttributedBody.text(in: input) else { return }
        sqlite3_result_text(context, body.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(body.count), transient)
    }

    private static func prepare(_ sql: String, _ database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v3(database, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard result == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw error(result, database)
        }
        return statement
    }

    private static func check(_ result: Int32, _ database: OpaquePointer, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw error(result, database) }
    }

    private static func error(_ code: Int32, _ database: OpaquePointer?) -> DatabaseError {
        let message = database.flatMap(sqlite3_errmsg).map { String(cString: $0) } ?? "Database unavailable"
        return .init(code: code, message: message)
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

extension MessagesAttachmentStore {
    struct ActivityChat {
        var key: MessagesActivitySortKey
        var guid: String
        var displayName: String
        var service: MessagesIPCService
        var type: MessagesIPCActivityChatType
        var counts: MessagesIPCActivityCount
    }

    private func activityQuery(_ filters: MessagesActivityFilters, from: Date?, to: Date,
                               upperBound: Int, chatRows: [Int]? = nil) throws -> (String, Bindings) {
        var bindings = Bindings()
        let chatType = """
            CASE WHEN instr(chat.guid, ';+;') > 0 THEN 'group'
                 WHEN instr(chat.guid, ';-;') > 0 THEN 'direct'
                 WHEN (SELECT COUNT(DISTINCT chj.handle_id) FROM messages.chat_handle_join chj
                       WHERE chj.chat_id = chat.ROWID) > 1 THEN 'group'
                 ELSE 'direct' END
            """
        var conditions = [String]()
        if !filters.chatGUIDs.isEmpty {
            let ids = filters.chatGUIDs.map { bindings.add(.text($0)) }.joined(separator: ", ")
            conditions.append("chat.guid IN (\(ids))")
        }
        if let type = filters.chatType {
            conditions.append("\(chatType) = \(bindings.add(.text(type.rawValue)))")
        }
        if let chatRows {
            let ids = chatRows.map { bindings.add(.integer(Int64($0))) }.joined(separator: ", ")
            conditions.append("chat.ROWID IN (\(ids))")
        }
        let lower = try from.map { try bindings.add(.integer(Self.activityDate($0, label: "fromDate"))) }
        let upper = try bindings.add(.integer(Self.activityDate(to, label: "toDate")))
        let bound = bindings.add(.integer(Int64(upperBound)))
        func branch(date: String, condition: String) -> String {
            let minimum = lower.map { "AND \(date) >= \($0)" } ?? ""
            return """
                SELECT filtered_chats.*, \(date) AS activity_date,
                    CASE WHEN COALESCE(message.is_from_me, 0) != 0 THEN 1 ELSE 0 END AS is_from_me
                FROM filtered_chats
                JOIN messages.chat_message_join cmj ON cmj.chat_id = filtered_chats.chat_row_id
                JOIN messages.message message ON message.ROWID = cmj.message_id
                WHERE \(condition) AND cmj.message_id <= \(bound) AND \(date) < \(upper) \(minimum)
                """
        }
        let whereChats = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return ("""
            WITH filtered_chats AS MATERIALIZED (
                SELECT chat.ROWID AS chat_row_id, chat.guid, chat.display_name, chat.service_name,
                    \(chatType) AS chat_type
                FROM messages.chat chat \(whereChats)
            ), activity AS (
                \(branch(date: "cmj.message_date", condition: "cmj.message_date != 0"))
                UNION ALL
                \(branch(date: "message.date", condition: "cmj.message_date = 0"))
                UNION ALL
                \(branch(date: "message.date", condition: "cmj.message_date IS NULL"))
            )
            """, bindings)
    }

    static func activityDate(_ date: Date, label: String) throws -> Int64 {
        guard let value = Int64(exactly: date.timeIntervalSinceReferenceDate * 1_000_000_000) else {
            throw MessagesReadValidationError.invalid("\(label) is outside the supported range")
        }
        return value
    }

    func earliestActivity(_ filters: MessagesActivityFilters, to: Date, upperBound: Int) throws -> Date? {
        let (query, bindings) = try activityQuery(filters, from: nil, to: to, upperBound: upperBound)
        let statement = try boundStatement(query + "\nSELECT MIN(activity_date) FROM activity", bindings)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_step(statement), database, expected: SQLITE_ROW)
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: Double(sqlite3_column_int64(statement, 0)) / 1_000_000_000)
    }

    private static let activityCounts = """
        COUNT(*) AS total, COALESCE(SUM(is_from_me), 0) AS sent,
        COALESCE(SUM(1 - is_from_me), 0) AS received
        """

    private static func activityCount(_ statement: OpaquePointer, at index: Int32) -> MessagesIPCActivityCount {
        .init(total: Int(sqlite3_column_int64(statement, index)), sent: Int(sqlite3_column_int64(statement, index + 1)),
              received: Int(sqlite3_column_int64(statement, index + 2)))
    }

    func overallActivity(_ filters: MessagesActivityFilters, range: MessagesIPCActivityRange,
                         upperBound: Int) throws -> (counts: MessagesIPCActivityCount, matchingChats: Int) {
        let (query, bindings) = try activityQuery(filters, from: range.from, to: range.to, upperBound: upperBound)
        let statement = try boundStatement(query + """
            
            SELECT \(Self.activityCounts), COUNT(DISTINCT chat_row_id) FROM activity
            """, bindings)
        defer { sqlite3_finalize(statement) }
        try Self.check(sqlite3_step(statement), database, expected: SQLITE_ROW)
        return (Self.activityCount(statement, at: 0), Int(sqlite3_column_int64(statement, 3)))
    }

    func rankedActivity(_ filters: MessagesActivityFilters, range: MessagesIPCActivityRange, upperBound: Int,
                        before: MessagesActivitySortKey?, limit: Int) throws -> (chats: [ActivityChat], matchingChats: Int) {
        var (query, bindings) = try activityQuery(filters, from: range.from, to: range.to, upperBound: upperBound)
        let cutoff = before.map { key in
            let count = bindings.add(.integer(Int64(key.count)))
            let row = bindings.add(.integer(Int64(key.chatRowID)))
            return "WHERE (rank_count, chat_row_id) < (\(count), \(row))"
        } ?? ""
        let rank: String
        switch filters.rankBy {
        case .total: rank = "total"
        case .sent: rank = "sent"
        case .received: rank = "received"
        }
        let maximum = bindings.add(.integer(Int64(limit)))
        query += """
            , chat_totals AS MATERIALIZED (
                SELECT chat_row_id, guid, display_name, service_name, chat_type, \(Self.activityCounts)
                FROM activity GROUP BY chat_row_id
            ), ranked AS (
                SELECT *, \(rank) AS rank_count, COUNT(*) OVER () AS matching_chat_count FROM chat_totals
            )
            SELECT * FROM ranked \(cutoff) ORDER BY rank_count DESC, chat_row_id DESC LIMIT \(maximum)
            """
        let statement = try boundStatement(query, bindings)
        defer { sqlite3_finalize(statement) }
        var chats = [ActivityChat]()
        var matching = 0
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return (chats, matching) }
            try Self.check(code, database, expected: SQLITE_ROW)
            matching = Int(sqlite3_column_int64(statement, 9))
            chats.append(.init(key: .init(count: Int(sqlite3_column_int64(statement, 8)),
                chatRowID: Int(sqlite3_column_int64(statement, 0))), guid: Self.text(statement, 1) ?? "",
                displayName: Self.text(statement, 2) ?? "", service: .init(raw: Self.text(statement, 3) ?? ""),
                type: Self.text(statement, 4) == "group" ? .group : .direct, counts: Self.activityCount(statement, at: 5)))
        }
    }

    private final class ActivityBucketEnds {
        let values: [Int64]

        init(_ buckets: [MessagesIPCActivityRange]) throws {
            values = try buckets.map { try MessagesAttachmentStore.activityDate($0.to, label: "activity bucket") }
        }

        func index(of date: Int64) -> Int {
            var lower = 0
            var upper = values.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if date < values[middle] { upper = middle } else { lower = middle + 1 }
            }
            return lower
        }
    }

    func activityBuckets(_ filters: MessagesActivityFilters, range: MessagesIPCActivityRange, upperBound: Int,
                         buckets: [MessagesIPCActivityRange], chatRows: [Int]? = nil) throws -> [Int: [Int: MessagesIPCActivityCount]] {
        guard !buckets.isEmpty, chatRows?.isEmpty != true else { return [:] }
        let ends = try ActivityBucketEnds(buckets)
        let context = Unmanaged.passRetained(ends).toOpaque()
        try Self.check(sqlite3_create_function_v2(database, "message_activity_bucket_index", 1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC, context, { context, _, arguments in
                guard let context, let data = sqlite3_user_data(context), let arguments else { return }
                let ends = Unmanaged<ActivityBucketEnds>.fromOpaque(data).takeUnretainedValue()
                sqlite3_result_int64(context, Int64(ends.index(of: sqlite3_value_int64(arguments[0]))))
            }, nil, nil, { context in
                if let context { Unmanaged<ActivityBucketEnds>.fromOpaque(context).release() }
            }), database)
        let (query, bindings) = try activityQuery(filters, from: range.from, to: range.to,
            upperBound: upperBound, chatRows: chatRows)
        let row = chatRows == nil ? "0" : "chat_row_id"
        let groups = chatRows == nil ? "bucket_index" : "chat_row_id, bucket_index"
        let statement = try boundStatement(query + """
            
            SELECT \(row), message_activity_bucket_index(activity_date) AS bucket_index, \(Self.activityCounts)
            FROM activity GROUP BY \(groups)
            """, bindings)
        defer { sqlite3_finalize(statement) }
        var result = [Int: [Int: MessagesIPCActivityCount]]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try Self.check(code, database, expected: SQLITE_ROW)
            let rowID = Int(sqlite3_column_int64(statement, 0))
            let bucket = Int(sqlite3_column_int64(statement, 1))
            result[rowID, default: [:]][bucket] = Self.activityCount(statement, at: 2)
        }
    }
}

extension MessagesAttachmentStore {
    struct SendChat {
        let rowID: Int64
        let guid: String
        let displayName: String
        let service: MessagesIPCService?
    }

    func sendChat(_ guid: String) throws -> SendChat? {
        var bindings = Bindings()
        let id = bindings.add(.text(guid))
        let statement = try boundStatement("""
            SELECT chat.ROWID, chat.guid, chat.display_name, chat.service_name
            FROM messages.chat chat WHERE chat.guid = \(id) ORDER BY chat.ROWID LIMIT 1
            """, bindings)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        try Self.check(code, database, expected: SQLITE_ROW)
        return SendChat(rowID: sqlite3_column_int64(statement, 0), guid: Self.text(statement, 1) ?? "",
            displayName: Self.text(statement, 2) ?? "", service: Self.text(statement, 3).map(MessagesIPCService.init(raw:)))
    }

    func sendChat(matching aliases: [[String]], normalize: (String) -> String) throws -> SendChat? {
        let groups = aliases.map { Set($0.map(normalize)) }
        let query = MessagesIPCFindChatsRequest(participants: [], exactParticipants: true, unreadOnly: false, limit: 1)
        guard let candidate = try findChats(query, aliases: groups.map { $0.sorted() }).first else { return nil }
        let handles = try participants(in: Int64(candidate.rowID)).map(normalize)
        let unique = Set(handles)
        guard handles.count == groups.count, unique.count == groups.count,
              handles.allSatisfy({ handle in groups.filter { $0.contains(handle) }.count == 1 }),
              groups.allSatisfy({ $0.intersection(unique).count == 1 }) else { return nil }
        return .init(rowID: Int64(candidate.rowID), guid: candidate.guid, displayName: candidate.displayName, service: candidate.service)
    }

    func latestService(for handle: String) throws -> MessagesIPCService? {
        var bindings = Bindings()
        let id = bindings.add(.text(handle))
        let statement = try boundStatement("""
            SELECT handle.service FROM messages.handle handle
            JOIN messages.chat_handle_join chj ON chj.handle_id = handle.ROWID
            JOIN messages.chat_message_join cmj ON cmj.chat_id = chj.chat_id
            JOIN messages.message message ON message.ROWID = cmj.message_id
            WHERE handle.id = \(id) ORDER BY message.date DESC LIMIT 1
            """, bindings)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        try Self.check(code, database, expected: SQLITE_ROW)
        return Self.text(statement, 0).map(MessagesIPCService.init(raw:))
    }
}
