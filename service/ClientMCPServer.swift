import Foundation
import MCP

/// Protocol/catalog shell shared by the five command domains.
/// A complete domain handler is required; this type never supplies a fallback
/// implementation for a known tool. Native operations and approvals belong in
/// that handler and retain the SDK's request context and server connection.
enum CUAMCPServer {
    typealias Handler = @Sendable (CUAMCPDomain, CallTool.Parameters, Server) async throws -> CallTool.Result

    static func make(catalog: CUAMCPToolCatalog, dispatchUnknownTools: Bool = false,
                     now: @escaping @Sendable () -> Date = Date.init, handler: @escaping Handler) async throws -> Server {
        let server = Server(name: catalog.domain.serverName, version: try catalog.definitionVersion,
            instructions: catalog.domain == .calendar
                ? "Tools for working with calendars and events in the macOS Calendar app." : nil,
            capabilities: .init(tools: .init(listChanged: catalog.domain == .calendar ? nil : false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: catalog.tools) }
        await server.withMethodHandler(CallTool.self) { parameters in
            // History measures the complete metadata-scoped invocation, with
            // its start date captured before extracting turn metadata.
            let startedAt = catalog.domain == .history ? now() : nil
            return try await CUAMCPInvocationContext.$startedAt.withValue(startedAt) {
              try await CUAMCPInvocationContext.withMetadata(parameters._meta) {
                guard dispatchUnknownTools || catalog.tools.contains(where: { $0.name == parameters.name }) else {
                    let message = "Unknown tool: " + parameters.name
                    let text = catalog.domain == .calendar ? String(describing: MCPError.invalidParams(message)) : message
                    return .init(content: [.text(text)], isError: true)
                }
                return try await handler(catalog.domain, parameters, server)
              }
            }
        }
        return server
    }

    static func run(catalog: CUAMCPToolCatalog, dispatchUnknownTools: Bool = false,
                    now: @escaping @Sendable () -> Date = Date.init, handler: @escaping Handler) async throws {
        let server = try await make(catalog: catalog, dispatchUnknownTools: dispatchUnknownTools, now: now, handler: handler)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
