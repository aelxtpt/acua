import ArgumentParser
import Foundation

extension AcuaMCPHost: ExpressibleByArgument {}
extension AcuaMCPServer: ExpressibleByArgument {}

struct AcuaMCPInstallOptions: ParsableArguments {
    @Option(help: "The MCP host: claude-code, cursor or generic.")
    var client: AcuaMCPHost

    @Option(name: .customLong("server"),
            help: "A server to configure: computer-use (default), calendar, computer-history, event-stream or messages. Repeat for several.")
    var servers: [AcuaMCPServer] = [.computerUse]

    @Flag(help: "Edit the host's configuration file instead of printing. Claude Code: ./.mcp.json. Cursor: ~/.cursor/mcp.json.")
    var write = false

    @Option(help: "The configuration file to edit with --write. Required for --client generic.")
    var config: String?

    func installer() throws -> AcuaMCPInstaller {
        // The host starts this same executable, wherever it is installed.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw AcuaMCPInstallError.executableUnavailable
        }

        return AcuaMCPInstaller(command: executable.path,
                                home: FileManager.default.homeDirectoryForCurrentUser,
                                currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    static func emit(_ output: AcuaMCPInstallOutput) {
        FileHandle.standardOutput.write(Data(output.standardOutput.utf8))
        FileHandle.standardError.write(Data(output.standardError.utf8))
    }
}

struct MCPInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install",
        abstract: "Prints, or writes with --write, the MCP host configuration that starts this client")

    @OptionGroup var options: AcuaMCPInstallOptions

    /// Written into each server's args.
    @OptionGroup var approval: AcuaMCPApprovalPromptOptions

    func run() throws {
        let output = try options.installer().install(host: options.client, servers: options.servers,
                                                     write: options.write, configuration: options.config,
                                                     approvalPrompt: approval.approvalPrompt)
        AcuaMCPInstallOptions.emit(output)
    }
}

struct MCPUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall",
        abstract: "Prints, or applies with --write, the removal of this client's servers from an MCP host configuration")

    @OptionGroup var options: AcuaMCPInstallOptions

    func run() throws {
        let output = try options.installer().uninstall(host: options.client, servers: options.servers,
                                                       write: options.write, configuration: options.config)
        AcuaMCPInstallOptions.emit(output)
    }
}
