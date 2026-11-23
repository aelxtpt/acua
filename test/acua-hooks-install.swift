import Foundation

// Unit tests for `hooks install` and `hooks uninstall`: the stop hook each
// agent runs when its turn ends, the edits of Claude Code's settings.json,
// Cursor's hooks.json and Codex's config.toml, and the printed instructions.
// Files live in a temporary directory; no agent is configured.

@main
enum AcuaHooksInstallTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static let executable = "/Users/someone/Library/Application Support/Aex Computer Use/AexComputerUseClient"
    private static let command = "'/Users/someone/Library/Application Support/Aex Computer Use/AexComputerUseClient' turn-ended --agent-process"

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acua-hooks-install-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func installer(_ directory: URL, executable: String = executable, environment: [String: String] = [:]) -> AcuaHooksInstaller {
        AcuaHooksInstaller(executable: executable, home: directory.appendingPathComponent("home"),
                           currentDirectory: directory.appendingPathComponent("project"), environment: environment)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func write(_ text: String, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    private static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func claudeStopCommands(_ url: URL) -> [String] {
        let groups = (json(url)?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private static func cursorStopCommands(_ url: URL) -> [String] {
        let entries = (json(url)?["hooks"] as? [String: Any])?["stop"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["command"] as? String }
    }

    private static func throwsError(_ expected: (AcuaHooksInstallError) -> Bool, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch let error as AcuaHooksInstallError {
            return expected(error)
        } catch {
            return false
        }
    }

    static func main() throws {
        hookCommands()
        defaultConfigurations()
        try claudeCodeSettings()
        try cursorHooks()
        try codexNotify()
        try installerWrites()
        try printedInstructions()
        print("\(passed) hooks install tests passed")
    }

    // MARK: - Hook command

    private static func hookCommands() {
        check("HookCommand_AgentProcess_QuotesTheInstallPath",
              AcuaHookCommand.agentProcess(executable: executable) == command, AcuaHookCommand.agentProcess(executable: executable))

        check("HookCommand_OurHook_IsRecognized", AcuaHookCommand.isAgentProcessHook(command))

        check("HookCommand_OurHookFromAnotherInstallPath_IsRecognized",
              AcuaHookCommand.isAgentProcessHook("/Applications/Other/AexComputerUseClient turn-ended --agent-process"))

        check("HookCommand_UserHook_IsNotOurs", !AcuaHookCommand.isAgentProcessHook("say done"))

        check("HookCommand_SameArgumentsOtherProgram_IsNotOurs",
              !AcuaHookCommand.isAgentProcessHook("/usr/local/bin/other turn-ended --agent-process"))

        check("CodexNotify_WithoutPrevious_EndsTurnsOnly",
              AcuaHookCommand.codexNotify(executable: executable, previous: nil) == [executable, "turn-ended"])

        check("CodexNotify_WithPrevious_ForwardsIt",
              AcuaHookCommand.codexNotify(executable: executable, previous: ["notify-send", "Codex"])
                  == [executable, "turn-ended", "--previous-notify", #"["notify-send","Codex"]"#])

        check("CodexNotify_OurNotify_IsRecognized",
              AcuaHookCommand.isCodexNotify(["/elsewhere/AexComputerUseClient", "turn-ended"]))

        check("CodexNotify_UserNotify_IsNotOurs", !AcuaHookCommand.isCodexNotify(["notify-send", "Codex"]))
    }

    // MARK: - Default files

    private static func defaultConfigurations() {
        let home = URL(fileURLWithPath: "/Users/someone")

        check("DefaultConfiguration_ClaudeCode_IsUserSettings",
              AcuaHookClient.claudeCode.defaultConfigurationURL(home: home, environment: [:]).path == "/Users/someone/.claude/settings.json")

        check("DefaultConfiguration_Cursor_IsUserHooks",
              AcuaHookClient.cursor.defaultConfigurationURL(home: home, environment: [:]).path == "/Users/someone/.cursor/hooks.json")

        check("DefaultConfiguration_Codex_IsCodexHomeConfig",
              AcuaHookClient.codex.defaultConfigurationURL(home: home, environment: [:]).path == "/Users/someone/.codex/config.toml")

        check("DefaultConfiguration_CodexHomeSet_IsThatConfig",
              AcuaHookClient.codex.defaultConfigurationURL(home: home, environment: ["CODEX_HOME": "/tmp/codex"]).path
                  == "/tmp/codex/config.toml")
    }

    // MARK: - Claude Code settings.json

    private static func claudeCodeSettings() throws {
        var empty = try AcuaClaudeCodeHookSettings(contents: nil, path: "settings.json")
        check("ClaudeSettings_MissingFile_AddsTheStopHook", try empty.install(command: command) == .added)
        let created = try JSONSerialization.jsonObject(with: empty.serialized()) as? [String: Any]
        let groups = (created?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        let hook = (groups?.first?["hooks"] as? [[String: Any]])?.first
        check("ClaudeSettings_AddedHook_IsACommandHook",
              hook?["type"] as? String == "command" && hook?["command"] as? String == command, "\(String(describing: created))")

        let existing = Data(#"""
            {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
             "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "check"}]}]}}
            """#.utf8)
        var settings = try AcuaClaudeCodeHookSettings(contents: existing, path: "settings.json")
        check("ClaudeSettings_OtherHooks_AddsBesideThem", try settings.install(command: command) == .added)
        let kept = try JSONSerialization.jsonObject(with: settings.serialized()) as? [String: Any]
        let keptHooks = kept?["hooks"] as? [String: Any]
        let stopCommands = (keptHooks?["Stop"] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        check("ClaudeSettings_Install_KeepsTheUsersStopHook", stopCommands == ["say done", command], "\(stopCommands)")
        check("ClaudeSettings_Install_KeepsOtherEventsAndKeys",
              keptHooks?["PreToolUse"] != nil && kept?["model"] as? String == "opus")

        var again = try AcuaClaudeCodeHookSettings(contents: try settings.serialized(), path: "settings.json")
        check("ClaudeSettings_InstalledTwice_IsUnchanged", try again.install(command: command) == .unchanged && !again.isModified)

        let moved = "/Applications/Aex/AexComputerUseClient turn-ended --agent-process"
        var relocated = try AcuaClaudeCodeHookSettings(contents: try settings.serialized(), path: "settings.json")
        check("ClaudeSettings_InstallPathChanged_UpdatesOurHook", try relocated.install(command: moved) == .updated)
        let relocatedCommands = (((try JSONSerialization.jsonObject(with: relocated.serialized()) as? [String: Any])?["hooks"]
            as? [String: Any])?["Stop"] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        check("ClaudeSettings_InstallPathChanged_LeavesOneHook", relocatedCommands == ["say done", moved], "\(relocatedCommands)")

        var removing = try AcuaClaudeCodeHookSettings(contents: try settings.serialized(), path: "settings.json")
        check("ClaudeSettings_Uninstall_RemovesOurHook", try removing.uninstall() == .removed)
        let afterRemoval = try JSONSerialization.jsonObject(with: removing.serialized()) as? [String: Any]
        let remainingStop = (afterRemoval?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        check("ClaudeSettings_Uninstall_KeepsTheUsersStopHook",
              remainingStop?.count == 1 && ((remainingStop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "say done")

        var onlyOurs = try AcuaClaudeCodeHookSettings(contents: try empty.serialized(), path: "settings.json")
        _ = try onlyOurs.uninstall()
        let emptied = try JSONSerialization.jsonObject(with: onlyOurs.serialized()) as? [String: Any]
        check("ClaudeSettings_UninstallOnlyHook_DropsTheEmptyHooksTable", emptied?["hooks"] == nil, "\(String(describing: emptied))")

        var absent = try AcuaClaudeCodeHookSettings(contents: existing, path: "settings.json")
        check("ClaudeSettings_UninstallWithoutOurHook_IsAbsent", try absent.uninstall() == .absent && !absent.isModified)

        check("ClaudeSettings_InvalidJSON_IsRejected", throwsError({ $0 == .invalidJSON(path: "settings.json") }) {
            _ = try AcuaClaudeCodeHookSettings(contents: Data("{".utf8), path: "settings.json")
        })

        check("ClaudeSettings_StopNotAnArray_IsRejected", throwsError({ $0 == .notAnArray(path: "settings.json", key: "hooks.Stop") }) {
            var settings = try AcuaClaudeCodeHookSettings(contents: Data(#"{"hooks":{"Stop":{}}}"#.utf8), path: "settings.json")
            _ = try settings.install(command: command)
        })
    }

    // MARK: - Cursor hooks.json

    private static func cursorHooks() throws {
        var empty = try AcuaCursorHooks(contents: nil, path: "hooks.json")
        check("CursorHooks_MissingFile_AddsTheStopHook", try empty.install(command: command) == .added)
        let created = try JSONSerialization.jsonObject(with: empty.serialized()) as? [String: Any]
        check("CursorHooks_MissingFile_WritesSchemaVersion1", created?["version"] as? Int == 1)
        check("CursorHooks_AddedHook_RunsTheCommand",
              ((created?["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])?.first?["command"] as? String == command)

        let existing = Data(#"{"version": 1, "hooks": {"stop": [{"command": "./hooks/audit.sh"}], "beforeShellExecution": [{"command": "x"}]}}"#.utf8)
        var hooks = try AcuaCursorHooks(contents: existing, path: "hooks.json")
        check("CursorHooks_OtherHooks_AddsBesideThem", try hooks.install(command: command) == .added)
        let kept = try JSONSerialization.jsonObject(with: hooks.serialized()) as? [String: Any]
        let keptHooks = kept?["hooks"] as? [String: Any]
        check("CursorHooks_Install_KeepsTheUsersHooks",
              (keptHooks?["stop"] as? [[String: Any]])?.compactMap { $0["command"] as? String } == ["./hooks/audit.sh", command]
                  && keptHooks?["beforeShellExecution"] != nil)

        var again = try AcuaCursorHooks(contents: try hooks.serialized(), path: "hooks.json")
        check("CursorHooks_InstalledTwice_IsUnchanged", try again.install(command: command) == .unchanged && !again.isModified)

        var removing = try AcuaCursorHooks(contents: try hooks.serialized(), path: "hooks.json")
        check("CursorHooks_Uninstall_RemovesOurHook", try removing.uninstall() == .removed)
        let afterRemoval = try JSONSerialization.jsonObject(with: removing.serialized()) as? [String: Any]
        check("CursorHooks_Uninstall_KeepsTheUsersHook",
              ((afterRemoval?["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])?.compactMap { $0["command"] as? String } == ["./hooks/audit.sh"])

        check("CursorHooks_HooksNotAnObject_IsRejected", throwsError({ $0 == .notAnObject(path: "hooks.json", key: "hooks") }) {
            var hooks = try AcuaCursorHooks(contents: Data(#"{"hooks":[]}"#.utf8), path: "hooks.json")
            _ = try hooks.install(command: command)
        })
    }

    // MARK: - Codex config.toml

    private static func codexNotify() throws {
        var empty = try AcuaCodexNotifyConfiguration(contents: nil, path: "config.toml")
        check("CodexNotify_MissingFile_AddsNotify", try empty.install(executable: executable) == .added)
        check("CodexNotify_MissingFile_WritesOneTopLevelKey",
              empty.serialized() == "notify = [\"\(executable)\", \"turn-ended\"]\n", empty.serialized())

        let withTables = """
            # Codex settings
            model = "gpt-5"

            [mcp_servers.computer-use]
            command = "x"
            """
        var tables = try AcuaCodexNotifyConfiguration(contents: withTables, path: "config.toml")
        _ = try tables.install(executable: executable)
        let lines = tables.serialized().components(separatedBy: "\n")
        let notifyLine = lines.firstIndex { $0.hasPrefix("notify = ") }
        let tableLine = lines.firstIndex { $0.hasPrefix("[mcp_servers") }
        check("CodexNotify_ConfigWithTables_PutsNotifyBeforeTheFirstTable",
              notifyLine != nil && tableLine != nil && notifyLine! < tableLine!, tables.serialized())
        check("CodexNotify_ConfigWithTables_KeepsEveryOtherLine",
              tables.serialized().contains("# Codex settings\nmodel = \"gpt-5\"\n") && tables.serialized().contains("command = \"x\""))

        let userNotify = "notify = [\"notify-send\", \"Codex\"]  # desktop banner\nmodel = \"gpt-5\"\n"
        var chained = try AcuaCodexNotifyConfiguration(contents: userNotify, path: "config.toml")
        check("CodexNotify_UserNotify_IsChained", try chained.install(executable: executable) == .updated)
        check("CodexNotify_UserNotify_IsForwardedThroughPreviousNotify",
              chained.notify == AcuaHookCommand.codexNotify(executable: executable, previous: ["notify-send", "Codex"]),
              "\(String(describing: chained.notify))")

        var again = try AcuaCodexNotifyConfiguration(contents: chained.serialized(), path: "config.toml")
        check("CodexNotify_InstalledTwice_IsUnchanged", try again.install(executable: executable) == .unchanged && !again.isModified)

        var relocated = try AcuaCodexNotifyConfiguration(contents: chained.serialized(), path: "config.toml")
        check("CodexNotify_InstallPathChanged_KeepsThePreviousNotify",
              try relocated.install(executable: "/Applications/Aex/AexComputerUseClient") == .updated
                  && relocated.notify == AcuaHookCommand.codexNotify(executable: "/Applications/Aex/AexComputerUseClient",
                                                                     previous: ["notify-send", "Codex"]))

        var restoring = try AcuaCodexNotifyConfiguration(contents: chained.serialized(), path: "config.toml")
        check("CodexNotify_Uninstall_RemovesOurs", try restoring.uninstall() == .removed)
        check("CodexNotify_Uninstall_RestoresTheUsersNotify",
              restoring.serialized() == "notify = [\"notify-send\", \"Codex\"]\nmodel = \"gpt-5\"\n", restoring.serialized())

        var removing = try AcuaCodexNotifyConfiguration(contents: empty.serialized() + "model = \"gpt-5\"\n", path: "config.toml")
        _ = try removing.uninstall()
        check("CodexNotify_UninstallWithoutPrevious_DeletesTheLine", removing.serialized() == "model = \"gpt-5\"\n", removing.serialized())

        var foreign = try AcuaCodexNotifyConfiguration(contents: userNotify, path: "config.toml")
        check("CodexNotify_UninstallUserNotify_IsAbsent", try foreign.uninstall() == .absent && !foreign.isModified)

        // A notify key inside a table is that table's, not Codex's top-level one.
        var inTable = try AcuaCodexNotifyConfiguration(contents: "[profiles.work]\nnotify = [\"x\"]\n", path: "config.toml")
        _ = try inTable.install(executable: executable)
        check("CodexNotify_NotifyInsideATable_IsLeftAlone",
              inTable.serialized().hasPrefix("notify = [\"\(executable)\", \"turn-ended\"]\n[profiles.work]\nnotify = [\"x\"]\n"),
              inTable.serialized())

        check("CodexNotify_MultilineArray_IsRejected", throwsError({ $0 == .notifyNotOneLineStringArray(path: "config.toml") }) {
            var config = try AcuaCodexNotifyConfiguration(contents: "notify = [\n  \"notify-send\",\n]\n", path: "config.toml")
            _ = try config.install(executable: executable)
        })

        check("CodexNotify_LiteralStrings_AreRejected", throwsError({ $0 == .notifyNotOneLineStringArray(path: "config.toml") }) {
            var config = try AcuaCodexNotifyConfiguration(contents: "notify = ['notify-send']\n", path: "config.toml")
            _ = try config.install(executable: executable)
        })

        let quoted = "/tmp/a \"b\"/AexComputerUseClient"
        var escaped = try AcuaCodexNotifyConfiguration(contents: nil, path: "config.toml")
        _ = try escaped.install(executable: quoted)
        let reread = try AcuaCodexNotifyConfiguration(contents: escaped.serialized(), path: "config.toml")
        check("CodexNotify_QuoteInPath_RoundTrips", reread.notify == [quoted, "turn-ended"], escaped.serialized())
    }

    // MARK: - Installer

    private static func installerWrites() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("home/.claude/settings.json")

        let installed = try installer(directory).install(client: .claudeCode, write: true, configuration: nil)
        check("Installer_ClaudeCodeWrite_EditsUserSettings", claudeStopCommands(settings) == [command], text(settings))
        check("Installer_ClaudeCodeWrite_ReportsTheFile",
              installed.standardOutput == "claude-code Stop hook: added in \(settings.path)\n", installed.standardOutput)
        check("Installer_ClaudeCodeWrite_AsksForARestart", installed.standardError.contains("Restart claude-code"))

        let removed = try installer(directory).uninstall(client: .claudeCode, write: true, configuration: nil)
        check("Installer_ClaudeCodeUninstall_RemovesTheHook", claudeStopCommands(settings).isEmpty
              && removed.standardOutput == "claude-code Stop hook: removed in \(settings.path)\n", removed.standardOutput)

        let cursor = directory.appendingPathComponent("home/.cursor/hooks.json")
        _ = try installer(directory).install(client: .cursor, write: true, configuration: nil)
        check("Installer_CursorWrite_EditsUserHooks", cursorStopCommands(cursor) == [command], text(cursor))

        let codexHome = directory.appendingPathComponent("codex")
        let codexConfig = codexHome.appendingPathComponent("config.toml")
        write("model = \"gpt-5\"\n", to: codexConfig)
        _ = try installer(directory, environment: ["CODEX_HOME": codexHome.path]).install(client: .codex, write: true, configuration: nil)
        check("Installer_CodexWrite_EditsCodexHomeConfig",
              text(codexConfig) == "notify = [\"\(executable)\", \"turn-ended\"]\nmodel = \"gpt-5\"\n", text(codexConfig))

        let project = directory.appendingPathComponent("project/.claude/settings.json")
        _ = try installer(directory).install(client: .claudeCode, write: true, configuration: ".claude/settings.json")
        check("Installer_RelativeConfig_ResolvesInTheCurrentDirectory", claudeStopCommands(project) == [command], project.path)

        let invalid = directory.appendingPathComponent("invalid.json")
        write("{", to: invalid)
        check("Installer_InvalidFile_IsLeftUntouched", throwsError({ $0 == .invalidJSON(path: invalid.path) }) {
            _ = try installer(directory).install(client: .cursor, write: true, configuration: invalid.path)
        } && text(invalid) == "{")
    }

    // MARK: - Printed instructions

    private static func printedInstructions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let claude = try installer(directory).install(client: .claudeCode, write: false, configuration: nil)
        let printed = try JSONSerialization.jsonObject(with: Data(claude.standardOutput.utf8)) as? [String: Any]
        let printedHook = (((printed?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        check("Printed_ClaudeCode_IsAStopHookSnippet", printedHook?["command"] as? String == command, claude.standardOutput)
        check("Printed_ClaudeCode_NamesTheSettingsFile", claude.standardError.contains(".claude/settings.json") && claude.standardError.contains("--write"))
        check("Printed_WithoutWrite_WritesNothing",
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("home/.claude/settings.json").path))

        let cursor = try installer(directory).install(client: .cursor, write: false, configuration: nil)
        let cursorSnippet = try JSONSerialization.jsonObject(with: Data(cursor.standardOutput.utf8)) as? [String: Any]
        check("Printed_Cursor_IsAVersion1HooksFile",
              cursorSnippet?["version"] as? Int == 1
                  && ((cursorSnippet?["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])?.first?["command"] as? String == command)

        let codex = try installer(directory).install(client: .codex, write: false, configuration: nil)
        check("Printed_Codex_IsTheNotifyLine", codex.standardOutput == "notify = [\"\(executable)\", \"turn-ended\"]\n", codex.standardOutput)
        check("Printed_Codex_MentionsAnExistingNotify", codex.standardError.contains("--previous-notify"))

        let uninstall = try installer(directory).uninstall(client: .cursor, write: false, configuration: nil)
        check("Printed_Uninstall_NamesTheHookToRemove",
              uninstall.standardOutput == command + "\n" && uninstall.standardError.contains(".cursor/hooks.json"), uninstall.standardOutput)

        check("Printed_ConfigWithoutWrite_IsRejected", throwsError({ $0 == .configurationWithoutWrite }) {
            _ = try installer(directory).install(client: .cursor, write: false, configuration: "hooks.json")
        })
    }
}
