import Foundation
import os
import SQLite3

@main enum MessagesImageTests {
    struct Failure: Error { let label: String }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label: label) }
        print("PASS \(label)")
    }

    static func expect(_ code: CUErrorCode, _ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw Failure(label: "expected \(message)")
        } catch let error as ServiceError {
            try check(error.code == code && error.message == message, message)
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-messages-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned chat.sqlite")
        let image = root.appendingPathComponent("image.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ZkAAAAASUVORK5CYII=")!
        try bytes.write(to: image)
        let broken = root.appendingPathComponent("broken.png")
        try Data("broken image".utf8).write(to: broken)
        try fixture(file, image: image, broken: broken)

        func request(_ attachment: Int64, _ chat: Int64 = 1) -> MessagesIPCReadImageRequest {
            .init(id: MessagesAttachmentID(attachmentRowID: attachment, chatRowID: chat)!.encoded)
        }
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let database: @Sendable () -> URL = {
            opens.withLock { $0 += 1 }
            return file
        }
        let contact: @Sendable (String) -> String? = { $0 == "alice@example.test" ? "Owned Alice" : nil }
        func execute(_ request: MessagesIPCReadImageRequest, _ access: MessagesPermissionDecision = .granted) throws -> MessagesIPCImage {
            try MessagesIPC.executeImage(request, permission: access, database: database, contactName: contact)
        }
        try expect(.messagesPermissionsPending, "Messages permission setup is still open") {
            _ = try execute(.init(id: "invalid"), .pending)
        }
        try expect(.messagesPermissionsDenied, "Required Messages permissions were not granted") {
            _ = try execute(request(1), .denied)
        }
        try expect(.messagesInvalidRequest, "image attachment id is invalid") {
            _ = try execute(.init(id: "invalid"))
        }
        try check(opens.withLock { $0 } == 0, "permission failures and invalid IDs stop before opening the database")

        let unnamed = try execute(request(1))
        try check(unnamed.data == bytes && unnamed.mimeType == "image/png" && unnamed.chatGUID == "owned"
            && unnamed.chatDisplayName == "Owned Alice, +155500001", "fixture returns the image and ordered participant names")
        let named = try execute(request(1, 2))
        try check(named.chatGUID == "owned-group" && named.chatDisplayName == "Owned Group", "explicit conversation name takes precedence")
        for item in [request(1, 99), request(2), request(4)] {
            try expect(.messagesInvalidRequest, "image attachment is unavailable") { _ = try execute(item) }
        }
        try expect(.messagesInvalidRequest, "image attachment could not be processed") { _ = try execute(request(3)) }
        try withExclusiveWriter(file) {
            let copied = try execute(request(1))
            try check(copied == unnamed, "locked database returns the committed attachment from an owned snapshot")
        }

        let grantedCalls = OSAllocatedUnfairLock(initialState: 0)
        let permission: @MainActor @Sendable () -> MessagesPermissionDecision = {
            grantedCalls.withLock { $0 += 1 }
            return .granted
        }
        let requestID = request(1).id
        try await Task.detached {
            try expect(.couldNotGetRequestData, "Could not decode ComputerUseIPCMessagesReadImageRequest") {
                _ = try MessagesIPC.readImage(request: ["id": false], permission: permission, database: database, contactName: contact)
            }
            try check(grantedCalls.withLock { $0 } == 0, "invalid wire data stops before permission presentation")
            let result = try MessagesIPC.readImage(request: ["id": requestID], permission: permission,
                database: database, contactName: contact)
            let data = try JSONSerialization.data(withJSONObject: result)
            try check(try JSONDecoder().decode(MessagesIPCImage.self, from: data) == unnamed,
                "connection worker returns the native image JSON fields")
        }.value
    }

    private static func fixture(_ file: URL, image: URL, broken: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open(file.path, &opened)
        defer { sqlite3_close(opened) }
        guard status == SQLITE_OK, let db = opened else { throw Failure(label: "open fixture") }
        let sql = """
            CREATE TABLE attachment (filename TEXT, hide_attachment INTEGER);
            CREATE TABLE message (guid TEXT);
            CREATE TABLE chat (guid TEXT, display_name TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            CREATE TABLE handle (id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES ('owned',NULL),('owned-group','Owned Group');
            INSERT INTO handle VALUES ('alice@example.test'),('+155500001');
            INSERT INTO chat_handle_join VALUES (1,2),(1,1);
            INSERT INTO message VALUES ('owned-message');
            INSERT INTO chat_message_join VALUES (1,1),(2,1);
            INSERT INTO message_attachment_join VALUES (1,1),(1,2),(1,3),(1,4);
            INSERT INTO attachment VALUES ('\(quote(image.path))',0),('\(quote(image.path))',1),
                ('\(quote(broken.path))',0),('\(quote(file.path + "-missing"))',0);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(label: String(cString: sqlite3_errmsg(db))) }
    }

    private static func withExclusiveWriter(_ file: URL, read: () throws -> Void) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open(file.path, &opened)
        defer { sqlite3_close(opened) }
        guard status == SQLITE_OK, let db = opened else { throw Failure(label: "open fixture writer") }
        guard sqlite3_exec(db, "BEGIN EXCLUSIVE; UPDATE chat SET display_name = 'Uncommitted'", nil, nil, nil) == SQLITE_OK else {
            throw Failure(label: "lock fixture writer")
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        try read()
    }

    private static func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}
