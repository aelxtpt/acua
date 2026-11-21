struct ControllerRequestConfiguration: Equatable, Sendable {
    let isAXTreeDiffingEnabled: Bool
    let mcpRuntime: UInt8
    init(sender: SenderRequestContext?) {
        // AX tree diffing needs a present context whose client type is nodeRepl.
        // The MCP runtime byte is 0 for legacy MCP, 1 for nodeRepl and 2 when absent.
        isAXTreeDiffingEnabled = sender?.clientMetadata.clientType == .nodeRepl
        switch sender?.clientMetadata.mcpRuntime {
        case .legacyMCP: mcpRuntime = 0
        case .nodeRepl: mcpRuntime = 1
        case nil: mcpRuntime = 2
        }
    }
}
