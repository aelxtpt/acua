import Darwin
import Foundation
import os
import SQLite3

@main enum MessagesSendPlanTests {
    struct Failure: Error { let label: String }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-send-plans-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.sqlite")
        try fixture(file)
        try await preparation(file)
        try await attempts()
        try await commitWorker(root)
        try await MainActor.run { try compose(root) }
    }

    static func preparation(_ file: URL) async throws {
        let matches: @Sendable (String) -> [MessagesSendTargets.RecipientMatch] = { input in
            switch input {
            case "Alice": return [.init(aliases: ["ALICE@example.test"], name: "Alice")]
            case "Alias": return [.init(aliases: ["alice@example.test"], name: "Alias")]
            case "Bob": return [.init(aliases: ["bob@example.test"], name: "Bob")]
            case "Ambiguous": return [.init(aliases: ["a@example.test"], name: nil), .init(aliases: ["b@example.test"], name: nil)]
            default: return []
            }
        }
        let contact: @Sendable (String) -> String? = { $0 == "alice@example.test" ? "Alice" : nil }
        let resolve: (MessagesSendPlans.Destination) throws -> MessagesSendPlans.Target = {
            try MessagesSendTargets.resolve($0, database: { file }, matches: matches, contactName: contact)
        }
        let plans = MessagesSendPlans()
        let fromChat = try plans.prepare(.init(chatGUID: " existing ", recipients: [], text: " draft ", attachments: []), resolve: resolve)
        try check(fromChat.chatGUID == "existing" && fromChat.displayName == "Alice" && fromChat.text == " draft ",
            "prepare resolves existing chat and preserves draft whitespace")
        let existing = try resolve(.recipients(["Alice"]))
        try check(existing.kind == .existingChat && existing.chatGUID == "existing", "prepare reuses an exact existing destination")
        let group = try resolve(.recipients(["Alice", "Bob"]))
        try check(group.kind == .newGroupMessage && group.displayName == "Alice, Bob" && group.chatGUID == nil
            && group.participants.map(\.handle) == ["alice@example.test", "bob@example.test"],
            "prepare preserves the order and normalized addresses of a new group")
        try expect(.messagesAmbiguousDestination, "recipient matches multiple contacts; retry with an exact phone number or email address") {
            _ = try resolve(.recipients(["Ambiguous"]))
        }
        do {
            _ = try resolve(.recipients(["Alice", "Alias"]))
            throw Failure(label: "duplicate address accepted")
        } catch let error as MessagesReadValidationError {
            try check(error.description.contains("different phone numbers"), "prepare rejects duplicate normalized recipients")
        }
        try await Task.detached {
            let body: [String: Any] = ["recipients": ["Bob"], "text": "owned draft", "attachments": []]
            let raw = try MessagesIPC.prepareSend(request: body, permission: { .granted }, database: { file },
                matches: matches, contactName: contact)
            let plan = try JSONDecoder().decode(MessagesIPCPreparedSend.self, from: JSONSerialization.data(withJSONObject: raw))
            try check(plan.chatGUID == nil && plan.displayName == "Bob" && plan.text == "owned draft",
                "connection worker prepares a typed draft without invoking delivery")
        }.value
    }

    static func attempts() async throws {
        let initial = Date(timeIntervalSinceReferenceDate: 500)
        let now = OSAllocatedUnfairLock(initialState: initial)
        let plans = MessagesSendPlans(now: { now.withLock { $0 } })
        let target = MessagesSendPlans.Target(kind: .existingChat, chatGUID: "owned", displayName: "Owned", participants: [], service: .iMessage)
        let attached = MessagesIPCSendAttachment(filename: "fixture.txt")
        let input = MessagesIPCPrepareSendRequest(chatGUID: "owned", recipients: [], text: "draft", attachments: [attached])
        let prepared = try plans.prepare(input) { _ in target }
        let commit = MessagesIPCCommitSendRequest(planID: prepared.planID, text: "approved")
        do {
            _ = try plans.claim(commit, fileCount: 0, authorize: { _ in }, stage: { _ in })
            throw Failure(label: "missing attachment accepted")
        } catch let error as MessagesReadValidationError {
            try check(error.description.contains("did not match"), "attachment mismatch leaves the plan available")
        }
        do {
            _ = try plans.claim(commit, fileCount: 1, authorize: { _ in }, stage: { _ in throw CocoaError(.fileReadUnknown) })
            throw Failure(label: "staging failure ignored")
        } catch is CocoaError {
            try check(true, "staging failure leaves the plan available")
        }
        let deliveryCount = OSAllocatedUnfairLock(initialState: 0)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        let (attempt, staged) = try plans.claim(commit, fileCount: 1, authorize: { _ in }, stage: { $0 })
                        deliveryCount.withLock { $0 += 1 }
                        return attempt.result.text == "approved" && staged == [attached]
                    } catch let error as ServiceError {
                        return error.code == .messagesSendPlanUnavailable && error.message.contains("already consumed")
                    } catch {
                        return false
                    }
                }
            }
            var results = [Bool]()
            for await outcome in group { results.append(outcome) }
            return results
        }
        try check(outcomes == [true, true] && deliveryCount.withLock { $0 } == 1,
            "two simultaneous confirmations reach the delivery sink once")

        let expiring = try plans.prepare(input) { _ in target }
        now.withLock { $0 = initial.addingTimeInterval(300) }
        try expect(.messagesSendPlanUnavailable, "Messages send plan is unavailable (expired).") {
            _ = try plans.claim(.init(planID: expiring.planID, text: nil), fileCount: 1, authorize: { _ in }, stage: { _ in })
        }
        now.withLock { $0 = initial.addingTimeInterval(600) }
        try expect(.messagesSendPlanUnavailable, "Messages send plan is unavailable (missing).") {
            _ = try plans.claim(.init(planID: expiring.planID, text: nil), fileCount: 1, authorize: { _ in }, stage: { _ in })
        }

        for _ in 0..<30 {
            let item = try plans.prepare(input) { _ in target }
            _ = try plans.claim(.init(planID: item.planID, text: nil), fileCount: 1, authorize: { _ in }, stage: { _ in })
        }
        let limited = try plans.prepare(input) { _ in target }
        try expect(.messagesSendRateLimited, "Messages sending is temporarily rate limited. Try again in 60 seconds.") {
            _ = try plans.claim(.init(planID: limited.planID, text: nil), fileCount: 1, authorize: { _ in }, stage: { _ in })
        }
        now.withLock { $0 = initial.addingTimeInterval(660) }
        let (resumed, _) = try plans.claim(.init(planID: limited.planID, text: nil), fileCount: 1, authorize: { _ in }, stage: { _ in })
        try check(resumed.attachments == [attached], "rate limiting leaves the prepared plan reusable once the window ends")
    }

    static func commitWorker(_ root: URL) async throws {
        let plans = MessagesSendPlans()
        let target = MessagesSendPlans.Target(kind: .existingChat, chatGUID: "owned", displayName: "Owned", participants: [], service: .iMessage)
        let input = MessagesIPCPrepareSendRequest(chatGUID: "owned", recipients: [], text: "draft",
            attachments: [.init(filename: "owned.bin/"), .init(filename: "owned.bin")])
        let plan = try plans.prepare(input) { _ in target }
        let failed = try plans.prepare(input) { _ in target }
        let data = Data([0, 1, 255, 13, 10])
        let source = root.appendingPathComponent("attachment")
        try data.write(to: source)
        let received = OSAllocatedUnfairLock(initialState: [URL]())
        try await Task.detached {
            let file = try FileHandle(forReadingFrom: source)
            try file.seek(toOffset: 2)
            let body = ["planID": plan.planID.uuidString, "text": "approved"]
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure(label: "open owned directory descriptor") }
            let readOnly = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try expect(.messagesPermissionsDenied, "Required Messages permissions were not granted") {
                _ = try MessagesIPC.commitSend(request: body, files: [file, file], plans: plans,
                    permission: { _ in .denied }, deliver: { _, _, _ in throw Failure(label: "delivery ran") })
            }
            try expect(.messagesInvalidRequest, "attachments must be regular files") {
                _ = try MessagesIPC.commitSend(request: body, files: [file, readOnly], plans: plans,
                    permission: { _ in .granted }, deliver: { _, _, _ in throw Failure(label: "delivery ran") })
            }
            let raw = try MessagesIPC.commitSend(request: body, files: [file, file], plans: plans,
                permission: { _ in .granted }, deliver: { attempt, staged, checkpoint in
                    try checkpoint()
                    try check(attempt.text == "approved" && staged.urls.count == 2
                        && staged.urls[0] != staged.urls[1] && staged.urls.map(\.lastPathComponent) == ["owned.bin", "owned.bin"],
                        "commit stages duplicate basenames separately and uses the approved text")
                    let copied = try staged.urls.map { try Data(contentsOf: $0) }
                    try check(copied == [data, data], "commit copies full regular file contents from the start")
                    received.withLock { $0 = staged.urls }
                })
            let result = try JSONDecoder().decode(MessagesIPCSendResult.self, from: JSONSerialization.data(withJSONObject: raw))
            try check(result.chatGUID == "owned" && result.text == "approved" && result.attachments == input.attachments,
                "commit returns the typed destination, approved body and prepared filenames")
            try check(received.withLock { $0 }.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                "commit removes staged files after the delivery adapter returns")

            let failedBody = ["planID": failed.planID.uuidString, "text": "approved"]
            try expect(.messagesSendOutcomeUncertain, "Messages delivery outcome is uncertain. The message may already have been sent.") {
                _ = try MessagesIPC.commitSend(request: failedBody, files: [file, file], plans: plans,
                    permission: { _ in .granted }, deliver: { _, _, _ in throw Failure(label: "delivery failed") })
            }
            try expect(.messagesSendPlanUnavailable, "Messages send plan was already consumed. Delivery may already have occurred.") {
                _ = try MessagesIPC.commitSend(request: failedBody, files: [], plans: plans,
                    permission: { _ in .granted }, deliver: { _, _, _ in throw Failure(label: "delivery ran again") })
            }
        }.value
    }

    @MainActor
    static func compose(_ root: URL) throws {
        let target = MessagesSendPlans.Target(kind: .newGroupMessage, chatGUID: nil, displayName: "Owned Group",
            participants: [.init(handle: "+15550001"), .init(handle: "sample@example.test")], service: nil)
        let attempt = MessagesSendPlans.Attempt(target: target, text: " A+B & C\n ", attachments: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 1))
        let url = try MessagesDelivery.composeURL(attempt)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        try check(components?.scheme == "sms" && components?.host == "open"
            && components?.queryItems?.first?.value == "+15550001,sample@example.test"
            && components?.queryItems?.last?.value == "A+B & C",
            "new conversation URL preserves ordered recipients and escapes the trimmed body")
        try check(MessagesDelivery.composerMatches("approved\u{FFFC}", expected: "approved", attachmentCount: 1)
            && !MessagesDelivery.composerMatches("approved\u{FFFC}", expected: "approved", attachmentCount: 0)
            && !MessagesDelivery.composerMatches("changed", expected: "approved", attachmentCount: 0),
            "new conversation guard rejects unexpected text and attachments")
        let file = root.appendingPathComponent("intent-fixture.txt")
        try Data("owned intent".utf8).write(to: file)
        let event = try MessagesDelivery.composeEvent(attempt, urls: [file], applicationURL: root)
        try check(event.eventClass == 0x61657674 && event.eventID == 0x6374706f
            && event.paramDescriptor(forKeyword: 0x74646175)?.data.isEmpty == false,
            "attachment intent serializes into the expected Apple event without opening the app")
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label: label) }
        print("PASS \(label)")
    }

    static func expect(_ code: CUErrorCode, _ message: String, _ action: () throws -> Void) throws {
        do {
            try action()
            throw Failure(label: "expected " + message)
        } catch let error as ServiceError {
            try check(error.code == code && error.message == message, message)
        }
    }

    static func fixture(_ file: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open(file.path, &opened)
        defer { sqlite3_close(opened) }
        guard status == SQLITE_OK, let db = opened else { throw Failure(label: "open fixture") }
        let sql = """
            CREATE TABLE chat (guid TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (guid TEXT, date INTEGER, is_from_me INTEGER, is_read INTEGER, item_type INTEGER,
                is_system_message INTEGER, is_finished INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE handle (id TEXT, service TEXT, uncanonicalized_id TEXT);
            CREATE TABLE attachment (hide_attachment INTEGER);
            INSERT INTO chat VALUES ('existing',NULL,'iMessage');
            INSERT INTO handle VALUES ('alice@example.test','iMessage',NULL);
            INSERT INTO chat_handle_join VALUES (1,1);
            INSERT INTO message VALUES ('owned-message',1000000000,1,1,0,0,1);
            INSERT INTO chat_message_join VALUES (1,1,1000000000);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(label: String(cString: sqlite3_errmsg(db))) }
    }
}
