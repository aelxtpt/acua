import Foundation
import os
import SQLite3

@main enum MessagesDiscoveryTests {
    struct Failure: Error { let label: String }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label: label) }
        print("PASS \(label)")
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        try fixture(file)
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let database: @Sendable () -> URL = { opens.withLock { $0 += 1 }; return file }
        let aliases: @Sendable (String) -> [String] = { $0 == "Owned Alice" ? ["alice@example.test"] : [] }
        let name: @Sendable (String) -> String? = { $0 == "alice@example.test" ? "Owned Alice" : nil }
        var find = MessagesIPCFindChatsRequest(participants: [], exactParticipants: true, unreadOnly: false, limit: 0)
        do {
            _ = try MessagesChatDiscovery.find(find, database: database, aliases: aliases, contactName: name)
            throw Failure(label: "empty exact participants accepted")
        } catch let error as MessagesReadValidationError {
            try check(error.description == "exactParticipants requires at least one participant", "exact mode validates participants before the limit")
        }
        let empty = try MessagesChatDiscovery.search(.init(query: "anything", limit: 0), database: database, aliases: aliases, contactName: name)
        try check(empty.chats.isEmpty && opens.withLock { $0 } == 0, "zero limit never opens the database")
        find.participants = ["not found"]
        find.limit = 2
        do {
            _ = try MessagesChatDiscovery.find(find, database: database, aliases: aliases, contactName: name)
            throw Failure(label: "unresolved name accepted")
        } catch let error as MessagesReadValidationError {
            try check(error.description.contains("was not found") && opens.withLock { $0 } == 0,
                "unresolved participant fails before database access")
        }

        find.participants = ["Owned Alice"]
        find.limit = 1
        let direct = try MessagesChatDiscovery.find(find, database: database, aliases: aliases, contactName: name)
        try check(direct.chats.map(\.guid) == ["owned-direct"] && !direct.hasMore,
            "exact alias excludes the chat containing an additional participant")
        try check(direct.chats.first?.displayName == "Owned Alice" && direct.chats.first?.participants == ["0"]
            && direct.participants.first?.service == .iMessage, "find uses Contacts display names and local participant references")
        find.exactParticipants = false
        let all = try MessagesChatDiscovery.find(find, database: database, aliases: aliases, contactName: name)
        try check(all.chats.map(\.guid) == ["owned-group"] && all.hasMore && all.participants.count == 2,
            "nonexact participant search returns the newest group and indicates a second result")

        let literal = try MessagesChatDiscovery.search(.init(query: " \n%\t", limit: 3),
            database: database, aliases: aliases, contactName: name)
        try check(literal.chats.map(\.guid) == ["owned-group"], "search treats percent literally after trimming whitespace")
        let preferred = try MessagesChatDiscovery.search(.init(query: "Owned Alice", limit: 1),
            database: database, aliases: aliases, contactName: name)
        try check(preferred.chats.map(\.guid) == ["owned-group"] && preferred.hasMore,
            "a contact alias discovers chats even when their titles differ")

        try await Task.detached {
            let body: [String: Any] = ["participants": ["Owned Alice"], "exactParticipants": true, "limit": 5, "unreadOnly": true]
            let raw = try MessagesIPC.findChats(request: body, permission: { .granted }, database: database,
                aliases: aliases, contactName: name)
            let result = try JSONDecoder().decode(MessagesIPCChatsPage.self, from: JSONSerialization.data(withJSONObject: raw))
            try check(result.chats.first?.unreadCount == 1 && result == direct, "worker returns the typed find page and unread count")
            let opened = opens.withLock { $0 }
            do {
                _ = try MessagesIPC.searchChats(request: ["query": "%", "limit": 1], permission: { .denied },
                    database: database, aliases: aliases, contactName: name)
                throw Failure(label: "permission denied but returned a result")
            } catch let error as ServiceError {
                try check(error.code == .messagesPermissionsDenied && opens.withLock { $0 } == opened,
                    "worker gates search before opening the database")
            }
        }.value
    }

    private static func fixture(_ file: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open(file.path, &opened)
        defer { sqlite3_close(opened) }
        guard status == SQLITE_OK, let db = opened else { throw Failure(label: "open fixture") }
        let sql = """
            CREATE TABLE chat (guid TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (date INTEGER, is_from_me INTEGER, item_type INTEGER, is_read INTEGER, is_finished INTEGER, is_system_message INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE handle (id TEXT, uncanonicalized_id TEXT, service TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES ('owned-direct',NULL,'iMessage'), ('owned-group','Owned 100%','iMessage'), ('owned-other','Other','SMS');
            INSERT INTO handle VALUES ('alice@example.test',NULL,'iMessage'), ('bob@example.test',NULL,'SMS');
            INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,2),(3,2);
            INSERT INTO message VALUES (1000000000,0,0,0,1,0), (3000000000,1,0,0,1,0), (4000000000,0,0,1,1,0);
            INSERT INTO chat_message_join VALUES (1,1,1000000000),(2,2,3000000000),(3,3,NULL);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(label: String(cString: sqlite3_errmsg(db))) }
    }
}
