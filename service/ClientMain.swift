import AppKit
import ArgumentParser
import os
import Darwin

/// `--http PORT` on every MCP server command.
struct AcuaMCPTransportOptions: ParsableArguments {
    @Option(name: .customLong("http"),
            help: "Serve MCP streamable HTTP on 127.0.0.1:PORT instead of stdio (0 picks a free port). The URL and a new token are printed to standard error.")
    var httpPort: Int?

    func validate() throws {
        guard let httpPort else { return }
        guard (0...Int(UInt16.max)).contains(httpPort) else {
            throw ValidationError("--http takes a port from 0 to 65535.")
        }
    }

    var transport: AcuaMCPTransport {
        httpPort.map { .http(port: UInt16($0)) } ?? .stdio
    }
}

/// `--approval-prompt` on every MCP server command. Its own group because
/// `mcp install` shares it: ArgumentParser gives an option the parent and a
/// subcommand both declare to the parent, so `install` must declare this
/// same group to receive a value written after its name.
struct AcuaMCPApprovalPromptOptions: ParsableArguments {
    @Option(name: .customLong(AcuaApprovalPrompt.optionName),
            help: "Who shows approval prompts: client (its own form when it supports elicitation, else the service dialog) or service (always the service dialog, for clients that decline forms without showing them).")
    var approvalPrompt: AcuaApprovalPrompt = .client
}

extension AcuaApprovalPrompt: ExpressibleByArgument {}

@main struct OwnedComputerUseClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cua", subcommands: [MCP.self, EventStream.self, ComputerHistory.self, Calendar.self, Messages.self, TurnEnded.self, HooksCommand.self])

    struct MCP: AsyncParsableCommand {
        // Without a subcommand `mcp` runs the server, as MCP hosts start it.
        static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Runs the Computer Use client as an MCP server",
                                                        discussion: "Without a subcommand, serves MCP on stdin and stdout. Use install to configure an MCP host.",
                                                        subcommands: [MCPInstallCommand.self, MCPUninstallCommand.self])
        @OptionGroup var transport: AcuaMCPTransportOptions
        @OptionGroup var approval: AcuaMCPApprovalPromptOptions

        mutating func run() async {
            signal(SIGPIPE, SIG_IGN)
            let storage = ClientMCPAutomationStorage.native()
            do {
                guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let catalog = try CUAMCPToolCatalog(domain: .automation, definitions: Data(contentsOf: definitions))
                try await CUAMCPServer.run(catalog: catalog, endTurn: .native(), transport: transport.transport, approvalPrompt: approval.approvalPrompt) {
                    let tracker = AutomationMCPTurnMetricsTracker(emit: { DiscardedTelemetry.drop($0) })
                    let backend = CUAMCPAutomation.native(store: .init(storageURL: storage.appApprovals), tracker: tracker,
                        approvalTelemetry: { DiscardedTelemetry.drop($0) }, toolTelemetry: { DiscardedTelemetry.drop($0) })
                    return { domain, parameters, server in
                        precondition(domain == .automation)
                        return try await backend.call(parameters, server: server)
                    }
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
            @OptionGroup var transport: AcuaMCPTransportOptions
            @OptionGroup var approval: AcuaMCPApprovalPromptOptions

            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .messages, definitions: Data(contentsOf: definitions))
                    let storage = ClientMCPMessagesStorage.native()
                    try await CUAMCPServer.run(catalog: catalog, transport: transport.transport, approvalPrompt: approval.approvalPrompt) {
                        let backend = CUAMCPMessages.native(readStore: .init(storageURL: storage.readDecisions),
                            sendStore: .init(storageURL: storage.sendApprovals))
                        return { domain, parameters, server in
                            precondition(domain == .messages)
                            return await backend.call(parameters, server: server)
                        }
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
            @OptionGroup var transport: AcuaMCPTransportOptions
            @OptionGroup var approval: AcuaMCPApprovalPromptOptions

            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .calendar, definitions: Data(contentsOf: definitions))
                    try await CUAMCPServer.run(catalog: catalog, transport: transport.transport, approvalPrompt: approval.approvalPrompt) {
                        let backend = CUAMCPCalendar.native()
                        return { domain, parameters, _ in
                            precondition(domain == .calendar)
                            return await backend.call(parameters)
                        }
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
            @OptionGroup var transport: AcuaMCPTransportOptions
            @OptionGroup var approval: AcuaMCPApprovalPromptOptions

            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .history, definitions: Data(contentsOf: definitions))
                    try await CUAMCPServer.run(catalog: catalog, dispatchUnknownTools: true, transport: transport.transport, approvalPrompt: approval.approvalPrompt) {
                        let backend = CUAMCPHistory.native(telemetry: { DiscardedTelemetry.drop($0) })
                        return { domain, parameters, _ in
                            precondition(domain == .history)
                            return await backend.call(parameters)
                        }
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
            @OptionGroup var transport: AcuaMCPTransportOptions
            @OptionGroup var approval: AcuaMCPApprovalPromptOptions

            mutating func run() async {
                signal(SIGPIPE, SIG_IGN)
                do {
                    guard let definitions = Bundle.main.url(forResource: "MCPToolDefinitions", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let catalog = try CUAMCPToolCatalog(domain: .eventStream, definitions: Data(contentsOf: definitions))
                    try await CUAMCPServer.run(catalog: catalog, transport: transport.transport, approvalPrompt: approval.approvalPrompt) {
                        let backend = CUAMCPEventStream.native(telemetry: { DiscardedTelemetry.drop($0) })
                        return { domain, parameters, server in
                            precondition(domain == .eventStream)
                            return await backend.call(parameters, server: server)
                        }
                    }
                } catch {
                    Logger(subsystem: "com.aex.computeruse.client", category: "EventStreamMCPServer")
                        .log("Error: Record & Replay MCP server failed: \(String(describing: error as NSError), privacy: .public)")
                }
            }
        }
    }

    struct TurnEnded: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "turn-ended",
            abstract: "Ends an agent turn: a Codex notify payload, or --agent-process from a Claude Code or Cursor stop hook")
        @Option var previousNotify: String?
        @Flag(help: "End the session of the agent process that runs this command, as the hooks install adds.")
        var agentProcess = false
        @Argument var notification: String?

        func validate() throws {
            guard agentProcess != (notification != nil) else {
                throw ValidationError("Pass either a Codex notification or --agent-process.")
            }
        }

        @MainActor mutating func run() async {
            let logger = Logger(subsystem: "com.aex.computeruse.client", category: "turn-ended")

            guard let notification else {
                let sessions = AcuaAgentProcessSession.hookSessionIDs(hookPID: getpid(), lookup: AcuaProcessTable.identity)
                let report = await AcuaAgentTurnEnded.run(sessionIDs: sessions,
                    findRunningService: { AcuaRunningService.find() }, send: { service, request in
                        try await ClientTurnEndedTransport.send(request, pid: service.processIdentifier)
                    })
                logger.log("\(report, privacy: .public)")
                FileHandle.standardError.write(Data((report + "\n").utf8))
                return
            }

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
