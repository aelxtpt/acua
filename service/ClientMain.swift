import AppKit
import ArgumentParser
import os
import Darwin

@main struct OwnedComputerUseClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cua", subcommands: [MCP.self, EventStream.self, ComputerHistory.self, Calendar.self, Messages.self, TurnEnded.self])

    struct MCP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Runs the Computer Use client as an MCP server")
        mutating func run() async {
            signal(SIGPIPE, SIG_IGN)
            let storage = ClientMCPAutomationStorage.native()
            do {
                guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let catalog = try CUAMCPToolCatalog(domain: .automation, definitions: Data(contentsOf: definitions))
                let tracker = AutomationMCPTurnMetricsTracker(emit: { DiscardedTelemetry.drop($0) })
                let backend = CUAMCPAutomation.native(store: .init(storageURL: storage.appApprovals), tracker: tracker,
                    approvalTelemetry: { DiscardedTelemetry.drop($0) }, toolTelemetry: { DiscardedTelemetry.drop($0) })
                try await CUAMCPServer.run(catalog: catalog, endTurn: .native()) { domain, parameters, server in
                    precondition(domain == .automation)
                    return try await backend.call(parameters, server: server)
                }
            } catch {
                Logger(subsystem: "com.aex.computeruse.client", category: "ComputerUseMCPServer")
                    .log("Error: Computer Use MCP server failed: \(String(describing: error as NSError), privacy: .public)")
            }
        }
    }

    struct Messages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "messages", subcommands: [MCP.self])
        struct MCP: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Runs the Messages client as an MCP server")
            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .messages, definitions: Data(contentsOf: definitions))
                    let storage = ClientMCPMessagesStorage.native()
                    let backend = CUAMCPMessages.native(readStore: .init(storageURL: storage.readDecisions),
                        sendStore: .init(storageURL: storage.sendApprovals))
                    try await CUAMCPServer.run(catalog: catalog) { domain, parameters, server in
                        precondition(domain == .messages)
                        return await backend.call(parameters, server: server)
                    }
                } catch {
                    Logger(subsystem: "com.aex.computeruse.client", category: "MessagesClient")
                        .log("Error: Messages MCP server failed: \(String(describing: error as NSError), privacy: .public)")
                }
            }
        }
    }

    struct Calendar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "calendar", subcommands: [MCP.self])
        struct MCP: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Runs the Calendar client as an MCP server")
            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .calendar, definitions: Data(contentsOf: definitions))
                    let backend = CUAMCPCalendar.native()
                    try await CUAMCPServer.run(catalog: catalog) { domain, parameters, _ in
                        precondition(domain == .calendar)
                        return await backend.call(parameters)
                    }
                } catch {
                    Logger(subsystem: "com.aex.computeruse.client", category: "CalendarMCPServer")
                        .error("log[8ab4d053e9b3d804e0ee] [0]=\(String(describing: error as NSError))")
                }
            }
        }
    }

    struct ComputerHistory: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "computer-history", subcommands: [MCP.self])
        struct MCP: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Runs the Computer History client as an MCP server")
            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .history, definitions: Data(contentsOf: definitions))
                    let backend = CUAMCPHistory.native(telemetry: { DiscardedTelemetry.drop($0) })
                    try await CUAMCPServer.run(catalog: catalog, dispatchUnknownTools: true) { domain, parameters, _ in
                        precondition(domain == .history)
                        return await backend.call(parameters)
                    }
                } catch {
                    Logger(subsystem: "com.aex.computeruse.client", category: "ComputerHistoryMCPServer")
                        .log("Error: Computer History MCP server failed: \(String(describing: error as NSError), privacy: .public)")
                }
            }
        }
    }

    struct EventStream: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "event-stream", subcommands: [MCP.self])

        struct MCP: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Runs the Record & Replay client as an MCP server")

            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .eventStream, definitions: Data(contentsOf: definitions))
                    let backend = CUAMCPEventStream.native(telemetry: { DiscardedTelemetry.drop($0) })
                    try await CUAMCPServer.run(catalog: catalog) { domain, parameters, server in
                        precondition(domain == .eventStream)
                        return await backend.call(parameters, server: server)
                    }
                } catch {
                    Logger(subsystem: "com.aex.computeruse.client", category: "EventStreamMCPServer")
                        .log("Error: Record & Replay MCP server failed: \(String(describing: error as NSError), privacy: .public)")
                }
            }
        }
    }

    struct TurnEnded: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "turn-ended", abstract: "Handles a Codex turn-ended notification")
        @Option var previousNotify: String?
        @Argument var notification: String

        @MainActor mutating func run() async {
            let logger = Logger(subsystem: "com.aex.computeruse.client", category: "turn-ended")
            await AgentTurnEnded.run(notification: notification, previousNotify: previousNotify,
                findRunningService: { AcuaRunningService.find() }, send: { service, request in
                    try await ClientTurnEndedTransport.send(request, pid: service.processIdentifier)
                }, diagnostic: { notification, error in
                    let turn = notification.turnID ?? "none"
                    logger.error("log[7108bf6971d7b5f26b17] [0]=\(notification.threadID, privacy: .public) [1]=\(turn, privacy: .public) [2]=\(String(describing: error as NSError))")
                })
        }
    }
}
