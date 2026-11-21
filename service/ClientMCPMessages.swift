import Foundation
import MCP

/// A domain owns its decision stores across calls, while each invocation uses
/// the actual connected SDK server for confirmations. Backend requests retain
/// their native types and attachment ownership across the send-plan lifecycle.
struct CUAMCPMessages: Sendable {
    let findChats: @Sendable (ComputerUseIPCMessagesFindChatsRequest) async throws -> ComputerUseIPCMessagesChatsPage
    let readMessages: @Sendable (ComputerUseIPCMessagesReadMessagesRequest) async throws -> ComputerUseIPCMessagesMessagesPage
    let searchMessages: @Sendable (ComputerUseIPCMessagesSearchMessagesRequest) async throws -> ComputerUseIPCMessagesMessagesPage
    let prepareSend: @Sendable (ComputerUseIPCMessagesPrepareSendRequest) async throws -> ComputerUseIPCMessagesPreparedSend
    let commitSend: @Sendable (ComputerUseIPCMessagesCommitSendRequest, [FileHandle]) async throws -> ComputerUseIPCMessagesSendResult
    let countActivity: @Sendable (ComputerUseIPCMessagesCountActivityRequest) async throws -> ComputerUseIPCMessagesActivityResult
    let readImage: @Sendable (ComputerUseIPCMessagesReadImageRequest) async throws -> ComputerUseIPCMessagesImage
    let readStore: MessagesReadDecisionStore
    let sendStore: MessagesSendApprovalStore
    let telemetry: @Sendable (CUAMessagesApprovalTelemetry) -> Void

    static let sendDeclined = "Message was not sent because the send was not approved. If the task's current approval_policy is confirmed to be never, explain, without naming the internal policy value, that the task's approval settings may have blocked the send confirmation, and suggest switching the task to Ask for approval or Approve for me before retrying. Otherwise, only report that the send was not approved; do not suggest changing approval settings."
    static let sendCanceled = "Message was not sent because the send approval was canceled."

    // Commit failures can occur after delivery. Preserve the known
    // rejection errors and report other failures as an uncertain outcome.
    private func commit(_ request: ComputerUseIPCMessagesCommitSendRequest, files: [FileHandle]) async throws -> ComputerUseIPCMessagesSendResult {
        do { return try await commitSend(request, files) }
        catch let error as ComputerUseIPCClient.Error {
            switch error {
            case .messagesInvalidRequest, .messagesSendPlanUnavailable, .messagesSendRateLimited,
                 .messagesPermissionsPending, .messagesPermissionsDenied, .messagesSendOutcomeUncertain:
                throw error
            default: throw ComputerUseIPCClient.Error.messagesSendOutcomeUncertain
            }
        } catch { throw ComputerUseIPCClient.Error.messagesSendOutcomeUncertain }
    }

    private func read(_ page: ComputerUseIPCMessagesMessagesPage, approval: MessagesMCPApproval) async throws -> CallTool.Result {
        // Keep the per-referenced-chat sequence: metadata lookup,
        // confirmation and access check occur before the next chat is visited.
        for reference in Set(page.messages.map(\.chat)) {
            guard let chat = page.chats.first(where: { $0.localRef == reference }) else {
                throw MessagesMCPToolError.invalidReadResponse
            }
            let access = try await approval.read([.init(guid: chat.guid, displayName: chat.displayName)])
            try MessagesMCPReadFiltering.require(chat.guid, access: access)
        }
        return try MessagesMCPFormatting.messages(page)
    }

    private func search(_ page: ComputerUseIPCMessagesMessagesPage, approval: MessagesMCPApproval) async throws -> CallTool.Result {
        let references = Set(page.messages.map(\.chat))
        let chats = page.chats.filter { references.contains($0.localRef) }
        guard Set(chats.map(\.localRef)) == references else { throw MessagesMCPToolError.invalidReadResponse }
        let access = try await approval.read(chats.map { .init(guid: $0.guid, displayName: $0.displayName) }, operation: .searchMessages)
        let allowed = Set(chats.filter { access.allowed.contains($0.guid) }.map(\.localRef))
        let blocked = Set(chats.filter { access.blockedBySettings.contains($0.guid) }.map(\.localRef))
        return try MessagesMCPReadFiltering.filter(page, allowed: allowed, blocked: blocked).result()
    }

    func call(_ parameters: CallTool.Parameters, server: Server) async -> CallTool.Result {
        do {
            let arguments = MessagesMCPArguments(parameters.arguments)
            let approval = MessagesMCPApproval(readStore: readStore, sendStore: sendStore, server: server, telemetry: telemetry)
            switch parameters.name {
            case "find_chats": return try await MessagesMCPFormatting.chats(findChats(arguments.findChats()))
            case "read_messages": return try await read(readMessages(arguments.readMessages()), approval: approval)
            case "search_messages": return try await search(searchMessages(arguments.searchMessages()), approval: approval)
            case "send_message":
                let arguments = try arguments.sendMessage()
                // Prepare carries names only. Descriptors are transferred to
                // Commit after approval.
                let plan = try await prepareSend(arguments.request)
                let decision = try await approval.send(plan)
                switch decision.action {
                case .decline: return .init(content: [.text(Self.sendDeclined)])
                case .cancel: return .init(content: [.text(Self.sendCanceled)])
                case .accept:
                    let sent = try await commit(.init(planID: plan.planID, text: decision.text), files: arguments.files)
                    return try MessagesMCPFormatting.sent(sent, userEdited: decision.userEdited)
                }
            case "count_message_activity": return try await MessagesMCPFormatting.activity(countActivity(arguments.countActivity()))
            case "read_image":
                let image = try await readImage(arguments.readImage())
                let access = try await approval.read([.init(guid: image.chatGUID, displayName: image.chatDisplayName)], operation: .readImage)
                try MessagesMCPReadFiltering.require(image.chatGUID, access: access)
                return MessagesMCPFormatting.image(image)
            default: throw MessagesMCPToolError.unknownTool(parameters.name)
            }
        } catch { return MessagesMCPFormatting.error(error, toolName: parameters.name) }
    }

    static func native(readStore: MessagesReadDecisionStore, sendStore: MessagesSendApprovalStore) -> Self {
        .init(findChats: { try await ComputerUseIPCClient.sendRequest($0) },
              readMessages: { try await ComputerUseIPCClient.sendRequest($0) },
              searchMessages: { try await ComputerUseIPCClient.sendRequest($0) },
              prepareSend: { try await ComputerUseIPCClient.sendRequest($0) },
              commitSend: { try await ComputerUseIPCClient.sendRequest($0, files: $1) },
              countActivity: { try await ComputerUseIPCClient.sendRequest($0) },
              readImage: { try await ComputerUseIPCClient.sendRequest($0) },
              readStore: readStore, sendStore: sendStore, telemetry: { DiscardedTelemetry.drop($0) })
    }
}
