import Foundation
import MCP
import os

struct MessagesMCPReadApprovalChat: Equatable, Sendable {
    let guid: String
    let displayName: String
}

struct MessagesMCPReadAccess: Equatable, Sendable {
    var allowed: Set<String>
    var blockedBySettings: Set<String>
}

struct MessagesMCPSendApproval: Equatable, Sendable {
    let action: CreateElicitation.Result.Action
    let text: String?
    let userEdited: Bool
}

/// Required elicitation injection allows the same gate to use the SDK server
/// in production and an isolated, scripted client in protocol checks.
struct MessagesMCPApproval: Sendable {
    typealias Elicit = @Sendable (String, Elicitation.RequestSchema) async throws -> CreateElicitation.Result
    let readStore: MessagesReadDecisionStore
    let sendStore: MessagesSendApprovalStore
    let elicit: Elicit
    let telemetry: @Sendable (CUAMessagesApprovalTelemetry) -> Void
    let onPersistenceFailure: @Sendable (_ reading: Bool, _ error: any Error) -> Void

    init(readStore: MessagesReadDecisionStore, sendStore: MessagesSendApprovalStore,
         elicit: @escaping Elicit,
         telemetry: @escaping @Sendable (CUAMessagesApprovalTelemetry) -> Void = { _ in },
         onPersistenceFailure: @escaping @Sendable (Bool, any Error) -> Void = { reading, error in
             let logger = Logger(subsystem: "com.aex.computeruse.client", category: "MessagesMCPServer")
             if reading {
                 logger.error("log[dcbec0e0dc7e1a100f02] [0]=\(String(describing: error as NSError))")
             } else {
                 logger.error("log[a4ff609d764914ebcfc6] [0]=\(String(describing: error as NSError))")
             }
         }) {
        self.readStore = readStore
        self.sendStore = sendStore
        self.elicit = elicit
        self.telemetry = telemetry
        self.onPersistenceFailure = onPersistenceFailure
    }

    init(readStore: MessagesReadDecisionStore, sendStore: MessagesSendApprovalStore, server: Server,
         telemetry: @escaping @Sendable (CUAMessagesApprovalTelemetry) -> Void = { _ in }) {
        self.init(readStore: readStore, sendStore: sendStore, elicit: { message, schema in
            try await server.requestElicitation(message: message, mode: .form, requestedSchema: schema)
        }, telemetry: telemetry)
    }

    static func readForm(_ chats: [MessagesMCPReadApprovalChat]) -> (message: String, schema: Elicitation.RequestSchema)? {
        guard let first = chats.first else { return nil }
        let sorted = chats.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        var scope: [String: Value] = [
            "type": .string("string"), "title": .string("Allow access:"),
            "oneOf": .array([
                .object(["const": .string("session"), "title": .string("For this conversation")]),
                .object(["const": .string("always"), "title": .string("Always")])
            ]), "default": .string("session")
        ]
        if chats.count > 4 {
            scope["description"] = .string(sorted.map { "“\($0.displayName)”" }
                .formatted(.list(type: .and, width: .standard).locale(Locale(identifier: "en_US"))))
        }
        var properties: [String: Value] = ["scope": .object(scope)]
        if (2...4).contains(chats.count) {
            properties["chats"] = .object([
                "type": .string("array"), "title": .string("Select chats:"),
                "items": .object(["anyOf": .array(sorted.map {
                    .object(["const": .string($0.guid), "title": .string($0.displayName)])
                })]), "default": .array([])
            ])
        }
        let message: String
        if chats.count > 4 {
            message = "Allow reading messages in these \(chats.count) chats?"
        } else if chats.count == 1 {
            let parts = first.guid.split(separator: ";", omittingEmptySubsequences: false)
            let isDirect = parts.count == 3 && parts[1] == "-"
            message = isDirect ? "Allow reading messages in your chat with “\(first.displayName)”?"
                : "Allow reading messages in “\(first.displayName)”?"
        } else {
            message = "Allow reading messages in the following chats?"
        }
        return (message, .init(properties: properties, required: ["scope"]))
    }

    private static func approvedChats(_ result: CreateElicitation.Result,
                                      chats: [MessagesMCPReadApprovalChat]) throws -> (Set<String>, permanent: Bool) {
        switch result.action {
        case .decline: return ([], false)
        case .cancel: throw MessagesMCPToolError.readApprovalCanceled
        case .accept: break
        }
        guard case .string(let scope) = result.content?["scope"], ["session", "always"].contains(scope) else {
            throw MessagesMCPToolError.invalidReadApprovalResponse
        }
        let all = Set(chats.map(\.guid))
        guard (2...4).contains(chats.count) else { return (all, scope == "always") }
        guard let selection = result.content?["chats"] else { return ([], scope == "always") }
        guard case .array(let values) = selection else { throw MessagesMCPToolError.invalidReadApprovalResponse }
        var selected = Set<String>()
        for value in values {
            guard case .string(let guid) = value, all.contains(guid) else {
                throw MessagesMCPToolError.invalidReadApprovalResponse
            }
            selected.insert(guid)
        }
        return (selected, scope == "always")
    }

    func read(_ chats: [MessagesMCPReadApprovalChat], operation: CUAMessagesApprovalOperation = .readMessages) async throws -> MessagesMCPReadAccess {
        var access = MessagesMCPReadAccess(allowed: [], blockedBySettings: [])
        var pending: [MessagesMCPReadApprovalChat] = []
        for chat in chats {
            switch await readStore.resolve(chatGUID: chat.guid, displayName: chat.displayName) {
            case .allow: access.allowed.insert(chat.guid)
            case .deny: access.blockedBySettings.insert(chat.guid)
            case .ask: pending.append(chat)
            }
        }
        guard let form = Self.readForm(pending) else { return access }
        telemetry(.requested(operation: operation, chatCount: Int64(pending.count)))
        var outcome = CUAMessagesApprovalResult.error
        var persistence: CUAMessagesApprovalPersistence?
        var approvedCount: Int64?
        defer { telemetry(.resolved(operation: operation, result: outcome, persistence: persistence, chatCount: approvedCount)) }
        let result = try await elicit(form.message, form.schema)
        if result.action == .decline { outcome = .declined; approvedCount = 0 }
        if result.action == .cancel { outcome = .canceled; approvedCount = 0 }
        let (selected, permanent) = try Self.approvedChats(result, chats: pending)
        for chat in pending where selected.contains(chat.guid) {
            if permanent {
                // Grant this response even when remembering the
                // decision fails. It logs the failure without a session grant.
                do { try await readStore.persist(chatGUID: chat.guid, displayName: chat.displayName, decision: .alwaysAllow) }
                catch { onPersistenceFailure(true, error) }
            } else {
                await readStore.approveForSession(chatGUID: chat.guid)
            }
        }
        access.allowed.formUnion(selected)
        if result.action == .accept {
            outcome = .accepted
            persistence = permanent ? .always : .session
            approvedCount = Int64(selected.count)
        }
        return access
    }

    static func sendForm(_ plan: ComputerUseIPCMessagesPreparedSend) -> (message: String, schema: Elicitation.RequestSchema) {
        var text: [String: Value] = [
            "type": .string("string"), "default": .string(plan.text ?? ""),
            "minLength": .int(plan.attachments.isEmpty ? 1 : 0), "maxLength": .int(10_000)
        ]
        if !plan.attachments.isEmpty {
            text["description"] = .string((plan.attachments.count == 1 ? "Attachment: " : "Attachments: ")
                + plan.attachments.map(\.filename).joined(separator: ", "))
        }
        var properties: [String: Value] = ["text": .object(text)]
        if plan.chatGUID != nil {
            properties["trust_chat"] = .object([
                "type": .string("boolean"), "title": .string("Always allow sending to this chat"), "default": .bool(false)
            ])
        }
        return ("Send this to “\(plan.displayName)”?",
            .init(properties: properties, required: plan.attachments.isEmpty ? ["text"] : []))
    }

    func send(_ plan: ComputerUseIPCMessagesPreparedSend) async throws -> MessagesMCPSendApproval {
        guard await sendStore.requiresApproval(chatGUID: plan.chatGUID, displayName: plan.displayName) else {
            return .init(action: .accept, text: plan.text, userEdited: false)
        }
        let form = Self.sendForm(plan)
        telemetry(.requested(operation: .sendMessage, chatCount: nil))
        var outcome = CUAMessagesApprovalResult.error
        var persistence: CUAMessagesApprovalPersistence?
        defer { telemetry(.resolved(operation: .sendMessage, result: outcome, persistence: persistence, chatCount: nil)) }
        let result = try await elicit(form.message, form.schema)
        guard result.action == .accept else {
            outcome = result.action == .decline ? .declined : .canceled
            return .init(action: result.action, text: nil, userEdited: false)
        }
        var text: String?
        if let approved = result.content?["text"] {
            guard case .string(let value) = approved, value.count <= 10_000 else {
                throw CalendarMCPArgumentError.invalid("the approved text must be a string of no more than 10000 characters")
            }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = value }
        }
        guard text != nil || !plan.attachments.isEmpty else {
            throw CalendarMCPArgumentError.invalid("the approved text must not be empty")
        }
        if let guid = plan.chatGUID, result.content?["trust_chat"] == .bool(true) {
            do { try await sendStore.persist(chatGUID: guid, displayName: plan.displayName) }
            catch { onPersistenceFailure(false, error) }
        }
        outcome = .accepted
        persistence = plan.chatGUID != nil && result.content?["trust_chat"] == .bool(true) ? .always : .once
        return .init(action: .accept, text: text, userEdited: text != plan.text)
    }
}
