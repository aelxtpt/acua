import Foundation
import MCP

/// Protocol/catalog shell shared by the five command domains.
/// A complete domain handler is required; this type never supplies a fallback
/// implementation for a known tool. Native operations and approvals belong in
/// that handler and retain the SDK's request context and server connection.
enum CUAMCPServer {
    typealias Handler = @Sendable (CUAMCPDomain, CallTool.Parameters, Server) async throws -> CallTool.Result

    /// `endTurn` adds the public `end_turn` tool to the catalog. Every call is
    /// tied to a session and turn through `turnScope`, named by the agent in
    /// `_meta` or implicit for this connection.
    static func make(catalog: CUAMCPToolCatalog, dispatchUnknownTools: Bool = false,
                     endTurn: AcuaMCPEndTurnTool? = nil, turnScope: AcuaMCPTurnScope = .init(),
                     clientCapabilities: CUAMCPClientCapabilities = .init(),
                     now: @escaping @Sendable () -> Date = Date.init, handler: @escaping Handler) async throws -> Server {
        let server = Server(name: catalog.domain.serverName, version: try catalog.definitionVersion,
            instructions: catalog.domain == .calendar
                ? "Tools for working with calendars and events in the macOS Calendar app." : nil,
            capabilities: .init(tools: .init(listChanged: catalog.domain == .calendar ? nil : false)))
        let tools = endTurn == nil ? catalog.tools : catalog.tools + [AcuaMCPEndTurnTool.definition]
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { parameters in
            // History measures the complete metadata-scoped invocation, with
            // its start date captured before extracting turn metadata.
            let startedAt = catalog.domain == .history ? now() : nil
            let turn: ComputerUseJSONRPCCodexTurnMetadata
            do { turn = try CUAMCPInvocationContext.turn(parameters._meta, scope: turnScope) }
            catch { return .init(content: [.text(String(describing: error))], isError: true) }
            let elicitation = clientCapabilities.supportsElicitation
            return try await CUAMCPInvocationContext.$startedAt.withValue(startedAt) {
              try await CUAMCPInvocationContext.$clientSupportsElicitation.withValue(elicitation) {
              try await CUAMCPInvocationContext.withTurn(turn) {
                if let endTurn, parameters.name == AcuaMCPEndTurnTool.name {
                    return await endTurn.call(parameters, scope: turnScope, callMetadata: turn)
                }
                guard dispatchUnknownTools || catalog.tools.contains(where: { $0.name == parameters.name }) else {
                    let message = "Unknown tool: " + parameters.name
                    let text = catalog.domain == .calendar ? String(describing: MCPError.invalidParams(message)) : message
                    return .init(content: [.text(text)], isError: true)
                }
                return try await handler(catalog.domain, parameters, server)
              }
              }
            }
        }
        return server
    }

    static func run(catalog: CUAMCPToolCatalog, dispatchUnknownTools: Bool = false, endTurn: AcuaMCPEndTurnTool? = nil,
                    now: @escaping @Sendable () -> Date = Date.init, handler: @escaping Handler) async throws {
        let capabilities = CUAMCPClientCapabilities()
        let server = try await make(catalog: catalog, dispatchUnknownTools: dispatchUnknownTools, endTurn: endTurn,
                                    clientCapabilities: capabilities, now: now, handler: handler)
        try await server.start(transport: StdioTransport()) { _, declared in capabilities.record(declared) }
        await server.waitUntilCompleted()
    }
}
