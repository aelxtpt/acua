/// Who shows the user an approval prompt: `--approval-prompt` on every MCP
/// server command, and on `mcp install` to write it into the host's entry.
enum AcuaApprovalPrompt: String, CaseIterable, Sendable {
    static let optionName = "approval-prompt"

    /// The MCP client's own form when it declared elicitation, the service's
    /// dialog otherwise. This is the default.
    case client

    /// Always the service's dialog. For clients that declare elicitation but
    /// answer every form without showing it: the Claude desktop app declines
    /// them, and Claude Code in print mode cancels them.
    case service

    /// The arguments that select this prompt on a server command. The default
    /// adds none, so existing host entries stay as they were.
    var serverArguments: [String] {
        self == .client ? [] : ["--" + Self.optionName, rawValue]
    }
}
