import ArgumentParser
import Foundation

extension AcuaHookClient: ExpressibleByArgument {}

struct AcuaHooksInstallOptions: ParsableArguments {
    @Option(help: "The agent: claude-code, cursor or codex.")
    var client: AcuaHookClient

    @Flag(help: "Edit the agent's file instead of printing. Claude Code: ~/.claude/settings.json. Cursor: ~/.cursor/hooks.json. Codex: $CODEX_HOME/config.toml.")
    var write = false

    @Option(help: "The file to edit with --write, for example a project's .claude/settings.json.")
    var config: String?

    func installer() throws -> AcuaHooksInstaller {
        // The agent runs this same executable, wherever it is installed.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw AcuaHooksInstallError.executableUnavailable
        }

        return AcuaHooksInstaller(executable: executable.path,
                                  home: FileManager.default.homeDirectoryForCurrentUser,
                                  currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                                  environment: ProcessInfo.processInfo.environment)
    }
}

struct HooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hooks",
        abstract: "Configures an agent to end its Computer Use turn when its own turn ends",
        discussion: "Optional: agents without hooks call the end_turn tool. Nothing is installed unless you run install.",
        subcommands: [HooksInstallCommand.self, HooksUninstallCommand.self])
}

struct HooksInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install",
        abstract: "Prints, or writes with --write, the agent hook that runs turn-ended")

    @OptionGroup var options: AcuaHooksInstallOptions

    func run() throws {
        let output = try options.installer().install(client: options.client, write: options.write, configuration: options.config)
        AcuaMCPInstallOptions.emit(output)
    }
}

struct HooksUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall",
        abstract: "Prints, or applies with --write, the removal of the hook that install added")

    @OptionGroup var options: AcuaHooksInstallOptions

    func run() throws {
        let output = try options.installer().uninstall(client: options.client, write: options.write, configuration: options.config)
        AcuaMCPInstallOptions.emit(output)
    }
}
