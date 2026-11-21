import Foundation
import MCP

enum MessagesMCPReadFiltering {
    struct FilteredPage: Sendable {
        let page: ComputerUseIPCMessagesMessagesPage
        let permissionFiltered: Bool?
        let permissionFilterMessage: String?
        func result() throws -> CallTool.Result {
            try MessagesMCPFormatting.messages(page, permissionFiltered: permissionFiltered,
                permissionFilterMessage: permissionFilterMessage)
        }
    }

    static let blockedReason = "read access was blocked by “Never allow” settings. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
    static let unapprovedReason = "read access was not approved. If the task's current approval_policy is confirmed to be never, explain, without naming the internal policy value, that the task's approval settings may have blocked the read confirmation, and suggest switching the task to Ask for approval or Approve for me before retrying. Otherwise, do not suggest changing approval settings or ask the user to approve access or retry. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
    static let mixedReason = "read access was not approved for some chats and was blocked by “Never allow” settings for others. If the task's current approval_policy is confirmed to be never, explain, without naming the internal policy value, that the task's approval settings may have blocked the read confirmation, and suggest switching the task to Ask for approval or Approve for me before retrying. Otherwise, do not suggest changing approval settings or ask the user to approve access or retry. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."

    /// Local references and the native page cursor are preserved. The filter
    /// removes sender metadata that belongs only to withheld messages.
    static func filter(_ page: ComputerUseIPCMessagesMessagesPage, allowed: Set<String>,
                       blocked: Set<String>) -> FilteredPage {
        let messages = page.messages.filter { allowed.contains($0.chat) }
        let senders = Set(messages.map(\.sender))
        let filtered = ComputerUseIPCMessagesMessagesPage(
            chats: page.chats.filter { allowed.contains($0.localRef) },
            senders: page.senders.filter { senders.contains($0.localRef) },
            messages: messages, nextCursor: page.nextCursor)
        guard messages.count < page.messages.count else {
            return .init(page: filtered, permissionFiltered: nil, permissionFilterMessage: nil)
        }
        let omitted = page.messages.filter { !allowed.contains($0.chat) }
        let reason = blocked.isEmpty ? unapprovedReason
            : omitted.allSatisfy({ blocked.contains($0.chat) }) ? blockedReason : mixedReason
        let prefix = messages.isEmpty ? "No messages were returned from this page because " : "Some messages were omitted because "
        return .init(page: filtered, permissionFiltered: true, permissionFilterMessage: prefix + reason)
    }

    static func require(_ guid: String, access: MessagesMCPReadAccess) throws {
        if access.blockedBySettings.contains(guid) { throw MessagesMCPToolError.readAccessBlockedBySettings }
        guard access.allowed.contains(guid) else { throw MessagesMCPToolError.readApprovalDenied }
    }
}
