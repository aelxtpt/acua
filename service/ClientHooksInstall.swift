import Foundation

/// An agent whose turn-end hook `hooks install` can configure.
enum AcuaHookClient: String, CaseIterable {
    case claudeCode = "claude-code"
    case cursor
    case codex

    /// User-level files, so the hook covers every project: Claude Code's
    /// settings.json, Cursor's hooks.json and Codex's config.toml.
    func defaultConfigurationURL(home: URL, environment: [String: String]) -> URL {
        switch self {
        case .claudeCode:
            return home.appendingPathComponent(".claude/settings.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/hooks.json")
        case .codex:
            let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            return codexHome.appendingPathComponent("config.toml")
        }
    }

    /// How the agent names the hook, for messages.
    var hookName: String {
        switch self {
        case .claudeCode: return "Stop hook"
        case .cursor: return "stop hook"
        case .codex: return "notify"
        }
    }
}

/// The commands an agent runs when its turn ends.
enum AcuaHookCommand {
    static let executableName = "AexComputerUseClient"
    static let turnEnded = "turn-ended"
    static let agentProcessArguments = [turnEnded, "--agent-process"]
    static let previousNotifyOption = "--previous-notify"

    /// A shell command line: Claude Code and Cursor run hooks through a shell.
    static func agentProcess(executable: String) -> String {
        ([executable] + agentProcessArguments).map(AcuaMCPInstaller.shellQuoted).joined(separator: " ")
    }

    /// Our hook, whatever path the client was installed at. Uninstall relies
    /// on this to remove only what install added.
    static func isAgentProcessHook(_ command: String) -> Bool {
        let suffix = " " + agentProcessArguments.joined(separator: " ")
        guard command.hasSuffix(suffix) else {
            return false
        }

        let program = command.dropLast(suffix.count).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return (program as NSString).lastPathComponent == executableName
    }

    /// Codex passes its turn-complete JSON as one more argument. A notify the
    /// user already had keeps running through --previous-notify.
    static func codexNotify(executable: String, previous: [String]?) -> [String] {
        guard let previous, !previous.isEmpty else {
            return [executable, turnEnded]
        }

        // Built from strings only, so encoding cannot fail.
        let encoded = String(decoding: try! JSONEncoder.withoutEscapingSlashes.encode(previous), as: UTF8.self)
        return [executable, turnEnded, previousNotifyOption, encoded]
    }

    static func isCodexNotify(_ notify: [String]) -> Bool {
        notify.count >= 2 && (notify[0] as NSString).lastPathComponent == executableName && notify[1] == turnEnded
    }

    /// The notify ours replaced, if any.
    static func previousCodexNotify(_ notify: [String]) -> [String]? {
        guard notify.count >= 4, notify[2] == previousNotifyOption else {
            return nil
        }

        return try? JSONDecoder().decode([String].self, from: Data(notify[3].utf8))
    }
}

private extension JSONEncoder {
    static var withoutEscapingSlashes: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }
}

enum AcuaHooksInstallError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidJSON(path: String)
    case rootNotObject(path: String)
    case notAnObject(path: String, key: String)
    case notAnArray(path: String, key: String)
    case notifyNotOneLineStringArray(path: String)
    case configurationWithoutWrite
    case executableUnavailable

    var description: String {
        switch self {
        case .invalidJSON(let path):
            return "\(path) is not valid JSON; fix it before installing."
        case .rootNotObject(let path):
            return "\(path) does not hold a JSON object."
        case .notAnObject(let path, let key):
            return "\"\(key)\" in \(path) is not an object."
        case .notAnArray(let path, let key):
            return "\"\(key)\" in \(path) is not an array."
        case .notifyNotOneLineStringArray(let path):
            return "notify in \(path) is not a one-line array of double-quoted strings; edit it by hand."
        case .configurationWithoutWrite:
            return "--config only applies with --write."
        case .executableUnavailable:
            return "Could not find this client's executable path."
        }
    }

    var errorDescription: String? { description }
}

/// A JSON object read from a hook file, edited by key path.
private struct AcuaJSONHookFile {
    let path: String
    var root: [String: Any]

    init(contents: Data?, path: String) throws {
        self.path = path

        guard let contents, !contents.isEmpty else {
            root = [:]
            return
        }

        guard let value = try? JSONSerialization.jsonObject(with: contents) else {
            throw AcuaHooksInstallError.invalidJSON(path: path)
        }

        guard let object = value as? [String: Any] else {
            throw AcuaHooksInstallError.rootNotObject(path: path)
        }

        root = object
    }

    func object(_ value: Any?, key: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw AcuaHooksInstallError.notAnObject(path: path, key: key)
        }
        return object
    }

    func objects(_ value: Any?, key: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw AcuaHooksInstallError.notAnArray(path: path, key: key)
        }
        return try array.map { try object($0, key: key) }
    }

    func serialized() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(Data("\n".utf8))
        return data
    }
}

/// Claude Code's settings.json:
/// {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "..."}]}]}}
struct AcuaClaudeCodeHookSettings {
    static let hooksKey = "hooks"
    static let stopKey = "Stop"
    static let commandKey = "command"

    private var file: AcuaJSONHookFile
    private(set) var isModified = false

    init(contents: Data?, path: String) throws {
        file = try AcuaJSONHookFile(contents: contents, path: path)
    }

    mutating func install(command: String) throws -> AcuaMCPConfigurationChange {
        var hooks = try file.object(file.root[Self.hooksKey], key: Self.hooksKey)
        var groups = try file.objects(hooks[Self.stopKey], key: "hooks.Stop")
        var change = AcuaMCPConfigurationChange.added

        for (groupIndex, group) in groups.enumerated() {
            var entries = try file.objects(group[Self.hooksKey], key: "hooks.Stop.hooks")
            guard let entryIndex = entries.firstIndex(where: { isOurs($0) }) else {
                continue
            }

            guard entries[entryIndex][Self.commandKey] as? String != command else {
                return .unchanged
            }

            // A hook from an earlier install path: point it at this one.
            entries[entryIndex][Self.commandKey] = command
            groups[groupIndex][Self.hooksKey] = entries
            change = .updated
            break
        }

        if change == .added {
            groups.append([Self.hooksKey: [["type": "command", Self.commandKey: command]]])
        }

        hooks[Self.stopKey] = groups
        file.root[Self.hooksKey] = hooks
        isModified = true
        return change
    }

    /// Removes our hook and any group or table that held only it.
    mutating func uninstall() throws -> AcuaMCPConfigurationChange {
        var hooks = try file.object(file.root[Self.hooksKey], key: Self.hooksKey)
        let groups = try file.objects(hooks[Self.stopKey], key: "hooks.Stop")
        var removed = false
        var kept: [[String: Any]] = []

        for var group in groups {
            let entries = try file.objects(group[Self.hooksKey], key: "hooks.Stop.hooks")
            let remaining = entries.filter { !isOurs($0) }

            guard remaining.count != entries.count else {
                kept.append(group)
                continue
            }

            removed = true
            guard !remaining.isEmpty else { continue }

            group[Self.hooksKey] = remaining
            kept.append(group)
        }

        guard removed else {
            return .absent
        }

        hooks[Self.stopKey] = kept.isEmpty ? nil : kept
        file.root[Self.hooksKey] = hooks.isEmpty ? nil : hooks
        isModified = true
        return .removed
    }

    func serialized() throws -> Data {
        try file.serialized()
    }

    private func isOurs(_ entry: [String: Any]) -> Bool {
        (entry[Self.commandKey] as? String).map(AcuaHookCommand.isAgentProcessHook) ?? false
    }
}

/// Cursor's hooks.json: {"version": 1, "hooks": {"stop": [{"command": "..."}]}}
struct AcuaCursorHooks {
    static let versionKey = "version"
    static let schemaVersion = 1
    static let hooksKey = "hooks"
    static let stopKey = "stop"
    static let commandKey = "command"

    private var file: AcuaJSONHookFile
    private(set) var isModified = false

    init(contents: Data?, path: String) throws {
        file = try AcuaJSONHookFile(contents: contents, path: path)
    }

    mutating func install(command: String) throws -> AcuaMCPConfigurationChange {
        var hooks = try file.object(file.root[Self.hooksKey], key: Self.hooksKey)
        var entries = try file.objects(hooks[Self.stopKey], key: "hooks.stop")
        var change = AcuaMCPConfigurationChange.added

        if let index = entries.firstIndex(where: { isOurs($0) }) {
            guard entries[index][Self.commandKey] as? String != command else {
                return .unchanged
            }

            entries[index][Self.commandKey] = command
            change = .updated
        } else {
            entries.append([Self.commandKey: command])
        }

        hooks[Self.stopKey] = entries
        file.root[Self.hooksKey] = hooks
        if file.root[Self.versionKey] == nil {
            file.root[Self.versionKey] = Self.schemaVersion
        }

        isModified = true
        return change
    }

    mutating func uninstall() throws -> AcuaMCPConfigurationChange {
        var hooks = try file.object(file.root[Self.hooksKey], key: Self.hooksKey)
        let entries = try file.objects(hooks[Self.stopKey], key: "hooks.stop")
        let remaining = entries.filter { !isOurs($0) }

        guard remaining.count != entries.count else {
            return .absent
        }

        hooks[Self.stopKey] = remaining.isEmpty ? nil : remaining
        file.root[Self.hooksKey] = hooks
        isModified = true
        return .removed
    }

    func serialized() throws -> Data {
        try file.serialized()
    }

    private func isOurs(_ entry: [String: Any]) -> Bool {
        (entry[Self.commandKey] as? String).map(AcuaHookCommand.isAgentProcessHook) ?? false
    }
}

/// The top-level `notify` key of Codex's config.toml, edited as text so the
/// user's comments and layout stay. The client has no TOML writer, so only a
/// one-line array of double-quoted strings is read; anything else is left for
/// the user to edit by hand.
struct AcuaCodexNotifyConfiguration {
    static let key = "notify"

    private let path: String
    private var lines: [String]
    private let endsWithNewline: Bool
    /// The line of the top-level notify key, if there is one.
    private var notifyLine: Int?
    /// Its value; nil when there is no key or it could not be read.
    private(set) var notify: [String]?
    /// A notify this cannot read is refused only when an edit needs it.
    private let notifyIsUnreadable: Bool
    private(set) var isModified = false

    init(contents: String?, path: String) throws {
        self.path = path
        let text = contents ?? ""
        endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        var split = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if endsWithNewline && !split.isEmpty {
            split.removeLast()
        }

        let line = Self.topLevelNotifyLine(split)
        let value = line.flatMap { Self.oneLineStringArray(split[$0]) }
        lines = split
        notifyLine = line
        notify = value
        notifyIsUnreadable = line != nil && value == nil
    }

    mutating func install(executable: String) throws -> AcuaMCPConfigurationChange {
        let current = try currentNotify()

        // Top-level keys must come before the first table, so the first line
        // is always a valid place.
        guard let current, let line = notifyLine else {
            let desired = AcuaHookCommand.codexNotify(executable: executable, previous: nil)
            lines.insert(Self.line(desired), at: 0)
            notifyLine = 0
            notify = desired
            isModified = true
            return .added
        }

        let previous = AcuaHookCommand.isCodexNotify(current) ? AcuaHookCommand.previousCodexNotify(current) : current
        let desired = AcuaHookCommand.codexNotify(executable: executable, previous: previous)
        guard desired != current else {
            return .unchanged
        }

        lines[line] = Self.line(desired)
        notify = desired
        isModified = true
        return .updated
    }

    /// Puts back the notify ours replaced, or deletes ours.
    mutating func uninstall() throws -> AcuaMCPConfigurationChange {
        guard let current = try currentNotify(), let line = notifyLine, AcuaHookCommand.isCodexNotify(current) else {
            return .absent
        }

        if let previous = AcuaHookCommand.previousCodexNotify(current) {
            lines[line] = Self.line(previous)
            notify = previous
        } else {
            lines.remove(at: line)
            notifyLine = nil
            notify = nil
        }

        isModified = true
        return .removed
    }

    func serialized() -> String {
        let text = lines.joined(separator: "\n")
        return endsWithNewline && !lines.isEmpty ? text + "\n" : text
    }

    private func currentNotify() throws -> [String]? {
        guard !notifyIsUnreadable else {
            throw AcuaHooksInstallError.notifyNotOneLineStringArray(path: path)
        }

        return notify
    }

    private static func isTableHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    /// Only keys before the first table header are top-level.
    private static func topLevelNotifyLine(_ lines: [String]) -> Int? {
        let end = lines.firstIndex(where: isTableHeader) ?? lines.count
        return lines[..<end].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { return false }
            return trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
    }

    /// `notify = ["a", "b"]  # comment`. TOML basic strings use the same
    /// escapes as JSON for anything this writes, so the array is decoded as
    /// JSON: the first `]` after which only a comment follows ends it.
    private static func oneLineStringArray(_ line: String) -> [String]? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

        for close in value.indices where value[close] == "]" {
            let rest = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#") else { continue }

            if let array = try? JSONDecoder().decode([String].self, from: Data(value[...close].utf8)) {
                return array
            }
        }

        return nil
    }

    private static func line(_ notify: [String]) -> String {
        // Built from strings only, so encoding cannot fail.
        let items = notify.map { String(decoding: try! JSONEncoder.withoutEscapingSlashes.encode($0), as: UTF8.self) }
        return "\(key) = [" + items.joined(separator: ", ") + "]"
    }
}

/// `hooks install` and `hooks uninstall`. Without `--write` they only print
/// what to add or remove; with it they edit one file. Nothing else writes
/// these files: ACUA never installs a hook on its own.
struct AcuaHooksInstaller {
    /// Absolute path of the client executable the hook runs.
    let executable: String
    let home: URL
    let currentDirectory: URL
    let environment: [String: String]

    func install(client: AcuaHookClient, write: Bool, configuration: String?) throws -> AcuaMCPInstallOutput {
        guard write else {
            guard configuration == nil else { throw AcuaHooksInstallError.configurationWithoutWrite }
            return printedInstallation(client)
        }

        let file = configurationFile(client, configuration: configuration)
        let change = try edit(client, file: file) { document in
            switch document {
            case .claudeCode(var settings):
                return (try settings.install(command: hookCommand), settings.isModified ? try settings.serialized() : nil)
            case .cursor(var hooks):
                return (try hooks.install(command: hookCommand), hooks.isModified ? try hooks.serialized() : nil)
            case .codex(var config):
                return (try config.install(executable: executable), config.isModified ? Data(config.serialized().utf8) : nil)
            }
        }

        return report(client, change: change, file: file)
    }

    func uninstall(client: AcuaHookClient, write: Bool, configuration: String?) throws -> AcuaMCPInstallOutput {
        guard write else {
            guard configuration == nil else { throw AcuaHooksInstallError.configurationWithoutWrite }
            return printedUninstallation(client)
        }

        let file = configurationFile(client, configuration: configuration)
        let change = try edit(client, file: file) { document in
            switch document {
            case .claudeCode(var settings):
                return (try settings.uninstall(), settings.isModified ? try settings.serialized() : nil)
            case .cursor(var hooks):
                return (try hooks.uninstall(), hooks.isModified ? try hooks.serialized() : nil)
            case .codex(var config):
                return (try config.uninstall(), config.isModified ? Data(config.serialized().utf8) : nil)
            }
        }

        return report(client, change: change, file: file)
    }

    private var hookCommand: String {
        AcuaHookCommand.agentProcess(executable: executable)
    }

    private enum Document {
        case claudeCode(AcuaClaudeCodeHookSettings)
        case cursor(AcuaCursorHooks)
        case codex(AcuaCodexNotifyConfiguration)
    }

    /// Reads the file, applies the edit and writes it back only if it changed.
    private func edit(_ client: AcuaHookClient, file: AcuaMCPConfigurationFile,
                      _ apply: (Document) throws -> (AcuaMCPConfigurationChange, Data?)) throws -> AcuaMCPConfigurationChange {
        let contents = try file.read()
        let path = file.url.path
        let document: Document

        switch client {
        case .claudeCode:
            document = .claudeCode(try AcuaClaudeCodeHookSettings(contents: contents, path: path))
        case .cursor:
            document = .cursor(try AcuaCursorHooks(contents: contents, path: path))
        case .codex:
            document = .codex(try AcuaCodexNotifyConfiguration(contents: contents.map { String(decoding: $0, as: UTF8.self) }, path: path))
        }

        let (change, updated) = try apply(document)
        if let updated {
            try file.write(updated)
        }
        return change
    }

    private func configurationFile(_ client: AcuaHookClient, configuration: String?) -> AcuaMCPConfigurationFile {
        guard let configuration else {
            return AcuaMCPConfigurationFile(url: client.defaultConfigurationURL(home: home, environment: environment))
        }

        // Not URL(fileURLWithPath:relativeTo:): a base without a trailing
        // slash resolves against its parent directory.
        let url = configuration.hasPrefix("/")
            ? URL(fileURLWithPath: configuration)
            : currentDirectory.appendingPathComponent(configuration)
        return AcuaMCPConfigurationFile(url: url.standardizedFileURL)
    }

    private func report(_ client: AcuaHookClient, change: AcuaMCPConfigurationChange, file: AcuaMCPConfigurationFile) -> AcuaMCPInstallOutput {
        AcuaMCPInstallOutput(standardOutput: "\(client.rawValue) \(client.hookName): \(change.rawValue) in \(file.url.path)\n",
                             standardError: "Restart \(client.rawValue) to load the change.\n")
    }

    private func printedInstallation(_ client: AcuaHookClient) -> AcuaMCPInstallOutput {
        let path = client.defaultConfigurationURL(home: home, environment: environment).path

        switch client {
        case .claudeCode:
            let snippet = Self.json([AcuaClaudeCodeHookSettings.hooksKey: [AcuaClaudeCodeHookSettings.stopKey:
                [[AcuaClaudeCodeHookSettings.hooksKey: [["type": "command", AcuaClaudeCodeHookSettings.commandKey: hookCommand]]]]]])
            return AcuaMCPInstallOutput(standardOutput: snippet,
                standardError: "Add this Stop hook to \(path) (or a project's .claude/settings.json), or rerun with --write.\n")
        case .cursor:
            let snippet = Self.json([AcuaCursorHooks.versionKey: AcuaCursorHooks.schemaVersion,
                                     AcuaCursorHooks.hooksKey: [AcuaCursorHooks.stopKey: [[AcuaCursorHooks.commandKey: hookCommand]]]])
            return AcuaMCPInstallOutput(standardOutput: snippet,
                standardError: "Add this stop hook to \(path), or rerun with --write.\n")
        case .codex:
            var config = try! AcuaCodexNotifyConfiguration(contents: nil, path: path)
            // A new file has no notify to parse, so this cannot throw.
            _ = try! config.install(executable: executable)
            return AcuaMCPInstallOutput(standardOutput: config.serialized(),
                standardError: "Set this top-level key in \(path). If you already have a notify, keep it running by "
                    + "adding \(AcuaHookCommand.previousNotifyOption) '<its JSON array>' after \(AcuaHookCommand.turnEnded), or rerun with --write.\n")
        }
    }

    private func printedUninstallation(_ client: AcuaHookClient) -> AcuaMCPInstallOutput {
        let path = client.defaultConfigurationURL(home: home, environment: environment).path

        guard client != .codex else {
            return AcuaMCPInstallOutput(standardOutput: "",
                standardError: "Remove the notify key that runs \(AcuaHookCommand.executableName) \(AcuaHookCommand.turnEnded) from \(path), "
                    + "putting back the array after \(AcuaHookCommand.previousNotifyOption) if there is one, or rerun with --write.\n")
        }

        return AcuaMCPInstallOutput(standardOutput: hookCommand + "\n",
            standardError: "Remove the \(client.hookName) that runs this command from \(path), or rerun with --write.\n")
    }

    private static func json(_ object: [String: Any]) -> String {
        // Built from strings, numbers and arrays only, so serialization cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
