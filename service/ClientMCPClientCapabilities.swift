import Foundation
import MCP

/// What the connected MCP client declared at `initialize`. The SDK keeps its
/// own copy private, so the server records it through the initialize hook.
///
/// Until `initialize` arrives the client is treated as not supporting
/// elicitation: the server must never send a request the client did not
/// declare.
final class CUAMCPClientCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var formElicitation = false
    let approvalPrompt: AcuaApprovalPrompt

    init(approvalPrompt: AcuaApprovalPrompt = .client) {
        self.approvalPrompt = approvalPrompt
    }

    var supportsElicitation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return formElicitation
    }

    /// Approvals go to the client's form only when it declared elicitation
    /// and `--approval-prompt` leaves the prompt to the client.
    var asksClientForApproval: Bool {
        guard approvalPrompt == .client else { return false }
        return supportsElicitation
    }

    func record(_ capabilities: Client.Capabilities) {
        lock.lock()
        defer { lock.unlock() }
        formElicitation = Self.supportsFormElicitation(capabilities)
    }

    /// Approval uses form elicitation. A client that declared only URL mode
    /// cannot show it. The SDK decodes `"elicitation": {}` as form mode.
    static func supportsFormElicitation(_ capabilities: Client.Capabilities) -> Bool {
        capabilities.elicitation?.form != nil
    }
}
