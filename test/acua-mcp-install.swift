import Foundation

// Unit tests for `mcp install` and `mcp uninstall`: the server entries, the
// edit of an "mcpServers" configuration file and the printed instructions.
// Files live in a temporary directory; no host is configured.

@main
enum AcuaMCPInstallTests {
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

    private static let command = "/Users/someone/Library/Application Support/Aex Computer Use/AexComputerUseClient"

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acua-mcp-install-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func installer(_ directory: URL) -> AcuaMCPInstaller {
        AcuaMCPInstaller(command: command, home: directory.appendingPathComponent("home"),
                         currentDirectory: directory.appendingPathComponent("project"))
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func servers(_ url: URL) -> [String: [String: Any]] {
        json(url)?["mcpServers"] as? [String: [String: Any]] ?? [:]
    }

    private static func throwsError(_ expected: (AcuaMCPInstallError) -> Bool, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch let error as AcuaMCPInstallError {
            return expected(error)
        } catch {
            return false
        }
    }

    static func main() throws {
        try entries()
        try documentEdits()
        try fileWrites()
        try printedInstructions()
        print("\(passed) MCP install tests passed")
    }

    private static func entries() throws {
        let computerUse = AcuaMCPServerEntry(server: .computerUse, command: command)
        check("Entry_ComputerUse_RunsClientMcp",
              computerUse.name == "acua" && computerUse.command == command && computerUse.arguments == ["mcp"])

        // Each optional catalog runs as `<domain> mcp`, the client's subcommands.
        let expected: [AcuaMCPServer: (String, [String])] = [
            .calendar: ("acua-calendar", ["calendar", "mcp"]),
            .computerHistory: ("acua-computer-history", ["computer-history", "mcp"]),
            .eventStream: ("acua-event-stream", ["event-stream", "mcp"]),
            .messages: ("acua-messages", ["messages", "mcp"]),
        ]
        for (server, (name, arguments)) in expected {
            let entry = AcuaMCPServerEntry(server: server, command: command)
            check("Entry_\(server.rawValue)_RunsDomainMcp", entry.name == name && entry.arguments == arguments,
                  "\(entry.name) \(entry.arguments)")
        }

        let names = AcuaMCPServer.allCases.map(\.configurationName)
        check("Entry_AllServers_HaveDistinctNames", Set(names).count == names.count)

        // --approval-prompt service travels to the server's own arguments; the
        // default adds nothing, so existing entries stay unchanged.
        let servicePrompt = AcuaMCPServerEntry(server: .computerUse, command: command, approvalPrompt: .service)
        check("Entry_ServiceApprovalPrompt_AppendsApprovalPromptArguments",
              servicePrompt.arguments == ["mcp", "--approval-prompt", "service"], "\(servicePrompt.arguments)")
        let serviceCalendar = AcuaMCPServerEntry(server: .calendar, command: command, approvalPrompt: .service)
        check("Entry_ServiceApprovalPromptForCatalog_AppendsAfterDomainMcp",
              serviceCalendar.arguments == ["calendar", "mcp", "--approval-prompt", "service"], "\(serviceCalendar.arguments)")
        let clientPrompt = AcuaMCPServerEntry(server: .computerUse, command: command, approvalPrompt: .client)
        check("Entry_ClientApprovalPrompt_KeepsDefaultArguments", clientPrompt.arguments == ["mcp"], "\(clientPrompt.arguments)")

        let home = URL(fileURLWithPath: "/Users/someone")
        let project = URL(fileURLWithPath: "/work/project")
        check("DefaultConfiguration_Cursor_IsHomeCursorMcpJson",
              AcuaMCPHost.cursor.defaultConfigurationURL(home: home, currentDirectory: project)?.path == "/Users/someone/.cursor/mcp.json")
        check("DefaultConfiguration_ClaudeCode_IsProjectMcpJson",
              AcuaMCPHost.claudeCode.defaultConfigurationURL(home: home, currentDirectory: project)?.path == "/work/project/.mcp.json")
        check("DefaultConfiguration_Generic_IsNone",
              AcuaMCPHost.generic.defaultConfigurationURL(home: home, currentDirectory: project) == nil)
    }

    private static func documentEdits() throws {
        let entry = AcuaMCPServerEntry(server: .computerUse, command: command)

        var empty = try AcuaMCPConfigurationDocument(contents: nil, path: "new.json")
        let added = try empty.install([entry])
        let createdRoot = try JSONSerialization.jsonObject(with: empty.serialized()) as? [String: Any]
        let createdEntry = (createdRoot?["mcpServers"] as? [String: Any])?["acua"] as? [String: Any]
        check("Install_MissingFile_AddsEntryUnderMcpServers",
              added.map(\.change) == [.added] && empty.isModified
                  && createdEntry?["command"] as? String == command && createdEntry?["args"] as? [String] == ["mcp"])

        // Other top-level keys, other servers and keys the user added to our
        // entry (env) all survive an update of the command.
        let existing = Data("""
            {"theme": "dark", "mcpServers": {"other": {"command": "/bin/other", "args": []},
             "acua": {"command": "/old/AexComputerUseClient", "args": ["mcp"], "env": {"A": "1"}}}}
            """.utf8)
        var update = try AcuaMCPConfigurationDocument(contents: existing, path: "existing.json")
        let updated = try update.install([entry])
        let updatedRoot = try JSONSerialization.jsonObject(with: update.serialized()) as? [String: Any]
        let updatedServers = updatedRoot?["mcpServers"] as? [String: [String: Any]]
        check("Install_EntryWithOldCommand_UpdatesCommand",
              updated.map(\.change) == [.updated] && updatedServers?["acua"]?["command"] as? String == command)
        check("Install_EntryWithUserKeys_KeepsThem", (updatedServers?["acua"]?["env"] as? [String: String]) == ["A": "1"])
        check("Install_ExistingFile_KeepsOtherServersAndKeys",
              updatedServers?["other"]?["command"] as? String == "/bin/other" && updatedRoot?["theme"] as? String == "dark")

        var same = try AcuaMCPConfigurationDocument(contents: try update.serialized(), path: "same.json")
        let unchanged = try same.install([entry])
        check("Install_SameEntryPresent_UnchangedAndNotModified", unchanged.map(\.change) == [.unchanged] && !same.isModified)

        check("Document_InvalidJSON_Throws", throwsError({ if case .invalidJSON = $0 { return true }; return false }) {
            _ = try AcuaMCPConfigurationDocument(contents: Data("{\"mcpServers\": ".utf8), path: "bad.json")
        })
        check("Document_RootArray_Throws", throwsError({ if case .rootNotObject = $0 { return true }; return false }) {
            _ = try AcuaMCPConfigurationDocument(contents: Data("[]".utf8), path: "array.json")
        })
        check("Install_McpServersNotObject_Throws", throwsError({ if case .serversNotObject = $0 { return true }; return false }) {
            var document = try AcuaMCPConfigurationDocument(contents: Data("{\"mcpServers\": []}".utf8), path: "servers.json")
            _ = try document.install([entry])
        })
        check("Install_EntryNotObject_Throws", throwsError({ if case .entryNotObject = $0 { return true }; return false }) {
            var document = try AcuaMCPConfigurationDocument(contents: Data("{\"mcpServers\": {\"acua\": 1}}".utf8), path: "entry.json")
            _ = try document.install([entry])
        })

        var removal = try AcuaMCPConfigurationDocument(contents: existing, path: "existing.json")
        let removed = try removal.uninstall(["acua", "acua-calendar"])
        let remaining = (try JSONSerialization.jsonObject(with: removal.serialized()) as? [String: Any])?["mcpServers"] as? [String: Any]
        check("Uninstall_PresentAndAbsentEntries_RemovesOnlyPresentOne",
              removed.map(\.change) == [.removed, .absent] && remaining.map { Array($0.keys) } == ["other"])

        var nothing = try AcuaMCPConfigurationDocument(contents: nil, path: "missing.json")
        let absent = try nothing.uninstall(["acua"])
        check("Uninstall_MissingFile_NotPresentAndNotModified", absent.map(\.change) == [.absent] && !nothing.isModified)
    }

    private static func fileWrites() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = installer(directory)
        let cursorFile = directory.appendingPathComponent("home/.cursor/mcp.json")

        // The Cursor directory does not exist yet.
        let first = try installer.install(host: .cursor, servers: [.computerUse, .calendar, .computerUse], write: true, configuration: nil)
        check("InstallWrite_CursorWithoutFile_CreatesHomeCursorMcpJson",
              Set(servers(cursorFile).keys) == ["acua", "acua-calendar"], first.standardOutput)
        check("InstallWrite_RepeatedServer_ConfiguredOnce", first.standardOutput.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2,
              first.standardOutput)

        let modified = try FileManager.default.attributesOfItem(atPath: cursorFile.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        let second = try installer.install(host: .cursor, servers: [.computerUse], write: true, configuration: nil)
        let unmodified = try FileManager.default.attributesOfItem(atPath: cursorFile.path)[.modificationDate] as? Date
        check("InstallWrite_AlreadyInstalled_ReportsUnchangedWithoutWriting",
              second.standardOutput.contains("acua: unchanged") && modified == unmodified, second.standardOutput)

        let removal = try installer.uninstall(host: .cursor, servers: [.calendar], write: true, configuration: nil)
        check("UninstallWrite_Cursor_RemovesOnlyThatServer",
              Array(servers(cursorFile).keys) == ["acua"] && removal.standardOutput.contains("acua-calendar: removed"))

        // Claude Code's --write goes to the project's .mcp.json.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("project"), withIntermediateDirectories: true)
        _ = try installer.install(host: .claudeCode, servers: [.computerUse], write: true, configuration: nil)
        check("InstallWrite_ClaudeCode_WritesProjectMcpJson",
              servers(directory.appendingPathComponent("project/.mcp.json"))["acua"]?["command"] as? String == command)

        // A relative --config resolves against the current directory.
        _ = try installer.install(host: .generic, servers: [.eventStream], write: true, configuration: "hosts/mcp.json")
        check("InstallWrite_RelativeConfig_ResolvesAgainstCurrentDirectory",
              servers(directory.appendingPathComponent("project/hosts/mcp.json"))["acua-event-stream"] != nil)

        check("InstallWrite_GenericWithoutConfig_Throws",
              throwsError({ if case .noDefaultConfiguration(.generic) = $0 { return true }; return false }) {
                  _ = try installer.install(host: .generic, servers: [.computerUse], write: true, configuration: nil)
              })
        check("Install_ConfigWithoutWrite_Throws",
              throwsError({ if case .configurationWithoutWrite = $0 { return true }; return false }) {
                  _ = try installer.install(host: .cursor, servers: [.computerUse], write: false, configuration: "x.json")
              })

        // An invalid file is reported and left byte for byte.
        let invalid = directory.appendingPathComponent("invalid.json")
        let invalidContents = Data("{ \"mcpServers\": { // comment\n } }".utf8)
        try invalidContents.write(to: invalid)
        let invalidRejected = throwsError({ if case .invalidJSON = $0 { return true }; return false }) {
            _ = try installer.install(host: .generic, servers: [.computerUse], write: true, configuration: invalid.path)
        }
        check("InstallWrite_InvalidJSON_ThrowsAndLeavesFile", invalidRejected && (try? Data(contentsOf: invalid)) == invalidContents)

        // A symlinked configuration is written at its target and stays a link;
        // the target keeps its permissions.
        let target = directory.appendingPathComponent("dotfiles/mcp.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try installer.install(host: .generic, servers: [.computerUse], write: true, configuration: link.path)
        let linkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let targetPermissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        check("InstallWrite_SymlinkedConfig_WritesTargetAndKeepsLink",
              linkDestination == target.path && servers(target)["acua"] != nil, String(describing: linkDestination))
        check("InstallWrite_ExistingFile_KeepsPermissions", targetPermissions == 0o600, String(describing: targetPermissions))
    }

    private static func printedInstructions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = installer(directory)

        let cursor = try installer.install(host: .cursor, servers: [.computerUse, .messages], write: false, configuration: nil)
        let snippet = (try? JSONSerialization.jsonObject(with: Data(cursor.standardOutput.utf8))) as? [String: Any]
        let snippetServers = snippet?["mcpServers"] as? [String: [String: Any]]
        check("InstallPrint_Cursor_PrintsParseableSnippet",
              snippetServers?["acua"]?["command"] as? String == command
                  && snippetServers?["acua-messages"]?["args"] as? [String] == ["messages", "mcp"], cursor.standardOutput)
        check("InstallPrint_Cursor_HintNamesConfigOnStandardError",
              cursor.standardError.contains("/home/.cursor/mcp.json") && !cursor.standardOutput.contains(".cursor"))
        check("InstallPrint_AnyHost_WritesNothing",
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == [])

        let claude = try installer.install(host: .claudeCode, servers: [.computerUse], write: false, configuration: nil)
        check("InstallPrint_ClaudeCode_PrintsQuotedMcpAddCommand",
              claude.standardOutput == "claude mcp add --scope user acua -- '\(command)' mcp\n", claude.standardOutput)

        let claudeService = try installer.install(host: .claudeCode, servers: [.computerUse], write: false,
                                                  configuration: nil, approvalPrompt: .service)
        check("InstallPrint_ClaudeCodeServiceApprovalPrompt_PrintsFlagAfterMcp",
              claudeService.standardOutput == "claude mcp add --scope user acua -- '\(command)' mcp --approval-prompt service\n",
              claudeService.standardOutput)

        let written = directory.appendingPathComponent("approval-prompt.json")
        _ = try installer.install(host: .generic, servers: [.computerUse], write: true, configuration: written.path,
                                  approvalPrompt: .service)
        check("InstallWrite_ServiceApprovalPrompt_WritesFlagInArgs",
              servers(written)["acua"]?["args"] as? [String] == ["mcp", "--approval-prompt", "service"])
        let reverted = try installer.install(host: .generic, servers: [.computerUse], write: true, configuration: written.path)
        check("InstallWrite_DefaultAfterServicePrompt_UpdatesArgsBack",
              servers(written)["acua"]?["args"] as? [String] == ["mcp"] && reverted.standardOutput.hasPrefix("acua: updated"),
              reverted.standardOutput)
        try? FileManager.default.removeItem(at: written)

        let claudeRemoval = try installer.uninstall(host: .claudeCode, servers: [.calendar], write: false, configuration: nil)
        check("UninstallPrint_ClaudeCode_PrintsMcpRemoveCommand",
              claudeRemoval.standardOutput == "claude mcp remove --scope user acua-calendar\n", claudeRemoval.standardOutput)

        check("ShellQuoted_SingleQuote_IsEscaped", AcuaMCPInstaller.shellQuoted("it's") == "'it'\\''s'")
        check("ShellQuoted_PlainWord_IsUnquoted", AcuaMCPInstaller.shellQuoted("acua-calendar") == "acua-calendar")
        check("ShellQuoted_Empty_IsQuoted", AcuaMCPInstaller.shellQuoted("") == "''")
    }
}
