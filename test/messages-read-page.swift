import Foundation
import os
import SQLite3

@main enum MessagesPageTests {
    struct Failure: Error { let label: String }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label: label) }
        print("PASS \(label)")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-messages-page-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.sqlite")
        try sql(file, """
            CREATE TABLE chat (guid TEXT, display_name TEXT);
            CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER,
                handle_id INTEGER, item_type INTEGER, is_read INTEGER, is_finished INTEGER, is_system_message INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE handle (id TEXT, service TEXT);
            CREATE TABLE attachment (filename TEXT, transfer_name TEXT, mime_type TEXT, total_bytes INTEGER, hide_attachment INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO chat VALUES ('owned',NULL), ('other','Other');
            INSERT INTO handle VALUES ('alice@example.test','iMessage'), ('+15550001','SMS');
            INSERT INTO chat_handle_join VALUES (1,2),(1,1);
            INSERT INTO message VALUES
                ('one','first',NULL,1000000000,0,1,0,1,1,0),
                ('two','tie lower',NULL,2000000000,0,1,0,0,1,0),
                ('three','tie higher',NULL,2000000000,1,NULL,0,0,1,0),
                ('four','no sender',NULL,3000000000,0,99,0,0,1,0),
                ('five','other',NULL,4000000000,0,2,0,0,1,0);
            INSERT INTO chat_message_join VALUES (1,1,1000000000),(1,2,0),(1,3,2000000000),(1,4,NULL),(2,5,4000000000);
            INSERT INTO attachment VALUES
                ('/private/tmp/raw.png','/owned/Named.png','image/png',28,0),
                ('/private/tmp/secret.png',NULL,'image/png',28,1),
                ('/private/tmp/fallback.png','','',-1,0);
            INSERT INTO message_attachment_join VALUES (2,1),(2,2),(2,3);
            """)
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let database: @Sendable () -> URL = { opens.withLock { $0 += 1 }; return file }
        let contact: @Sendable (String) -> String? = { $0 == "alice@example.test" ? "Alice" : nil }
        var query = MessagesIPCReadMessagesRequest(chatGUID: "owned", unreadOnly: false, limit: 2, cursor: "broken")
        do {
            _ = try MessagesReadPage.make(query, database: database, contactName: contact)
            throw Failure(label: "invalid cursor accepted")
        } catch MessagesPaging.CursorError.malformed {}
        query.limit = 0
        let empty = try MessagesReadPage.make(query, database: database, contactName: contact)
        try check(empty.messages.isEmpty && opens.withLock { $0 } == 0, "invalid cursor and zero limit stop before opening the database")

        query.limit = 2
        query.cursor = nil
        query.chatGUID = " \nowned\t"
        let first = try MessagesReadPage.make(query, database: database, contactName: contact)
        try check(first.messages.map(\.body) == ["no sender", "tie higher"], "read uses fallback dates and row IDs to sort ties")
        try check(first.messages.map(\.sender) == ["unknown", "me"] && first.senders.isEmpty,
            "read distinguishes own messages from a missing sender")
        try check(first.chats == [.init(localRef: "0", guid: "owned", displayName: "Alice, +15550001")],
            "read resolves the display name through ordered participants")
        let filters = MessagesReadFilters(chatGUID: "owned", unreadOnly: false)
        let next = try MessagesPaging.read(first.nextCursor!, filters: filters)
        try check(next.messageRowIDUpperBound == 5 && next.lastReturnedSortKey.rowID == 3, "cursor stores the first-page bound and last returned row")
        query.chatGUID = "owned"

        try sql(file, """
            INSERT INTO message VALUES ('new','inserted later',NULL,1500000000,0,2,0,0,1,0);
            INSERT INTO chat_message_join VALUES (1,6,1500000000);
            """)
        query.cursor = first.nextCursor
        query.limit = 100
        let second = try MessagesReadPage.make(query, database: database, contactName: contact)
        try check(second.messages.map(\.body) == ["tie lower", "first"] && second.nextCursor == nil,
            "next page excludes newly inserted rows and accepts a different limit")
        try check(second.senders == [.init(localRef: "0", handle: "alice@example.test", name: "Alice", service: .iMessage)]
            && second.messages.map(\.sender) == ["0", "0"], "read deduplicates senders and includes their service")
        let files = second.messages[0].attachments ?? []
        try check(files.count == 2 && files[0].filename == "Named.png" && files[0].sizeBytes == 28
            && files[1].filename == "fallback.png" && files[1].sizeBytes == nil && files[1].mimeType == nil
            && second.messages[1].attachments == nil, "read filters hidden attachments and normalizes metadata")
        try check(MessagesAttachmentID(encoded: files[0].id) == MessagesAttachmentID(attachmentRowID: 1, chatRowID: 1),
            "message attachment ID is usable by ReadImage")

        query.cursor = nil
        query.unreadOnly = true
        let unread = try MessagesReadPage.make(query, database: database, contactName: contact)
        try check(unread.messages.map(\.body) == ["no sender", "tie lower", "inserted later"]
            && unread.messages.allSatisfy { $0.isUnread == true }, "a fresh unread query sees newly inserted rows")
        let cursor = first.nextCursor!
        try await Task.detached {
            let body: [String: Any] = ["chatGUID": "owned", "limit": 5, "unreadOnly": false]
            let response = try MessagesIPC.readMessages(request: body, permission: { .granted }, database: database, contactName: contact)
            let data = try JSONSerialization.data(withJSONObject: response)
            let page = try JSONDecoder().decode(MessagesIPCMessagesPage.self, from: data)
            try check(page.messages.count == 5, "connection worker returns the complete typed page")
            var modified = body
            modified["unreadOnly"] = true
            modified["cursor"] = cursor
            do {
                _ = try MessagesIPC.readMessages(request: modified, permission: { .granted }, database: database, contactName: contact)
                throw Failure(label: "filter mismatch accepted")
            } catch let error as ServiceError {
                try check(error.code == .messagesInvalidRequest && error.message.contains("does not match"),
                    "a changed filter maps to the native cursor error")
            }
        }.value

        try sql(file, """
            ALTER TABLE message ADD COLUMN associated_message_type INTEGER;
            ALTER TABLE handle ADD COLUMN uncanonicalized_id TEXT;
            UPDATE message SET text = 'literal %_' WHERE ROWID = 2;
            UPDATE message SET text = 'literal %_', associated_message_type = 2000 WHERE ROWID = 3;
            INSERT INTO chat_message_join VALUES (2,2,9000000000);
            """)
        let aliases: @Sendable (String) -> [String] = { [$0] }
        var search = MessagesIPCSearchMessagesRequest(text: "  %_  ", chatGUIDs: ["other", " owned ", "other"],
            participants: [], exactParticipants: false, limit: 1)
        let searchFirst = try MessagesReadPage.search(search, database: database, aliases: aliases, contactName: contact)
        try check(searchFirst.chats.map(\.guid) == ["other"] && searchFirst.messages.map(\.body) == ["literal %_"],
            "search treats wildcard characters literally and uses the chat row ID to break a shared message tie")
        guard let searchCursor = searchFirst.nextCursor else { throw Failure(label: "search cursor missing") }
        try sql(file, """
            UPDATE message SET text = 'literal %_' WHERE ROWID = 1;
            INSERT INTO message VALUES ('new-search','literal %_',NULL,1500000000,1,NULL,0,0,1,0,NULL);
            INSERT INTO chat_message_join VALUES (1,7,1500000000);
            """)
        search.chatGUIDs = ["owned", "other"]
        search.text = "%_"
        search.cursor = searchCursor
        search.limit = 4
        let searchRest = try MessagesReadPage.search(search, database: database, aliases: aliases, contactName: contact)
        try check(searchRest.chats.map(\.guid) == ["owned"] && searchRest.messages.map(\.date.timeIntervalSinceReferenceDate) == [2, 1]
            && searchRest.nextCursor == nil, "search pagination normalizes filters and excludes reactions and newly inserted rows")

        try await Task.detached {
            var body: [String: Any] = ["text": "%_", "chatGUIDs": ["owned"], "participants": ["alice@example.test"],
                "exactParticipants": false, "limit": 1]
            let response = try MessagesIPC.searchMessages(request: body, permission: { .granted },
                database: database, aliases: aliases, contactName: contact)
            let data = try JSONSerialization.data(withJSONObject: response)
            let page = try JSONDecoder().decode(MessagesIPCMessagesPage.self, from: data)
            try check(page.senders.first?.name == "Alice" && page.nextCursor != nil,
                "connection worker returns a typed search page with a sender and a cursor")
            body["cursor"] = searchCursor
            do {
                _ = try MessagesIPC.searchMessages(request: body, permission: { .granted },
                    database: database, aliases: aliases, contactName: contact)
                throw Failure(label: "search accepted a cursor for different filters")
            } catch let error as ServiceError {
                try check(error.code == .messagesInvalidRequest && error.message.contains("does not match"),
                    "search maps filter changes to the cursor error")
            }
        }.value

        try await testActivity(file, database: database, contact: contact)
    }

    static func testActivity(_ file: URL, database: @escaping @Sendable () -> URL,
                             contact: @escaping @Sendable (String) -> String?) async throws {
        try sql(file, "ALTER TABLE chat ADD COLUMN service_name TEXT; UPDATE chat SET service_name = 'iMessage';")
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = Date(timeIntervalSinceReferenceDate: 10)
        let zone = TimeZone(identifier: "UTC")!
        var query = MessagesIPCCountActivityRequest(fromDate: start, toDate: end, interval: .total,
            chatGUIDs: [" other ", "owned", "other"], breakdown: .chat, rankBy: .sent, chatLimit: 1)
        let first = try MessagesActivity.count(query, database: database, contactName: contact, timeZone: zone)
        try check(first.matchingChatCount == 2 && first.chats?.first?.type == .group
            && first.chats?.first?.total == 6 && first.participants?.first?.name == "Alice",
            "activity classifies a legacy group and counts sent and received rows per conversation")
        guard let cursor = first.nextCursor else { throw Failure(label: "activity cursor missing") }
        try sql(file, """
            INSERT INTO message VALUES ('new-activity',NULL,NULL,4000000000,0,1,0,0,1,0,NULL);
            INSERT INTO chat_message_join VALUES (2,8,4000000000);
            """)
        query.cursor = cursor
        query.chatGUIDs = ["owned", "other"]
        let second = try MessagesActivity.count(query, database: database, contactName: contact,
            timeZone: TimeZone(identifier: "America/New_York")!)
        try check(second.timeZoneIdentifier == first.timeZoneIdentifier && second.chats?.first?.guid == "other"
            && second.chats?.first?.total == 2 && second.nextCursor == nil,
            "activity continuation retains the original zone and skips rows inserted after the first page")

        let utc = try MessagesActivity.makeBuckets(.init(from: start, to: start.addingTimeInterval(367 * 86_400)),
            interval: .week, timeZone: zone)
        try check(utc.first?.to == start.addingTimeInterval(7 * 86_400),
            "activity weeks start on Monday")

        try await Task.detached {
            let response = try MessagesIPC.countActivity(request: [
                "fromDate": 0, "toDate": 10, "interval": "total", "chatGUIDs": [],
                "breakdown": "overall", "rankBy": "total", "chatLimit": 10
            ], permission: { .granted }, database: database, contactName: contact)
            let result = try JSONDecoder().decode(MessagesIPCActivityResult.self, from: JSONSerialization.data(withJSONObject: response))
            try check(result.overallActivity?.total == 9 && result.chats == nil,
                "activity connection worker returns the typed overall result")
        }.value
    }

    static func sql(_ file: URL, _ source: String) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open(file.path, &opened)
        defer { sqlite3_close(opened) }
        guard status == SQLITE_OK, let db = opened else { throw Failure(label: "open fixture") }
        guard sqlite3_exec(db, source, nil, nil, nil) == SQLITE_OK else { throw Failure(label: String(cString: sqlite3_errmsg(db))) }
    }
}
