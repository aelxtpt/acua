import Foundation

/// The MCP hosts that `mcp install` knows how to configure.
enum AcuaMCPHost: String, CaseIterable {
    case claudeCode = "claude-code"
    case cursor
    case generic

    /// Where `--write` edits the host's configuration when `--config` is not
    /// given. Claude Code keeps its user-scope servers inside its own state
    /// file, which it rewrites while running, so only the project-scope
    /// `.mcp.json` is written; the user scope goes through `claude mcp add`.
    func defaultConfigurationURL(home: URL, currentDirectory: URL) -> URL? {
        switch self {
        case .claudeCode: return currentDirectory.appendingPathComponent(".mcp.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .generic: return nil
        }
    }
}

/// The stdio MCP servers the client runs. Each one is a separate entry in the
/// host's configuration.
enum AcuaMCPServer: String, CaseIterable {
    case computerUse = "computer-use"
    case calendar
    case computerHistory = "computer-history"
    case eventStream = "event-stream"
    case messages

    /// The key under "mcpServers".
    var configurationName: String {
        self == .computerUse ? "acua" : "acua-\(rawValue)"
    }

    /// The client arguments that start this server: `mcp` for computer use,
    /// `<domain> mcp` for the optional catalogs.
    var arguments: [String] {
        self == .computerUse ? ["mcp"] : [rawValue, "mcp"]
    }
}

/// One server as a host starts it.
struct AcuaMCPServerEntry: Equatable {
    static let commandKey = "command"
    static let argumentsKey = "args"

    let name: String
    let command: String
    let arguments: [String]

    init(server: AcuaMCPServer, command: String) {
        name = server.configurationName
        self.command = command
        arguments = server.arguments
    }

    var json: [String: Any] {
        [Self.commandKey: command, Self.argumentsKey: arguments]
    }
}

enum AcuaMCPConfigurationChange: String {
    case added
    case updated
    case unchanged
    case removed
    case absent = "not present"
}

enum AcuaMCPInstallError: Error, CustomStringConvertible, LocalizedError {
    case invalidJSON(path: String)
    case rootNotObject(path: String)
    case serversNotObject(path: String)
    case entryNotObject(path: String, name: String)
    case noDefaultConfiguration(host: AcuaMCPHost)
    case configurationWithoutWrite
    case executableUnavailable

    var description: String {
        switch self {
        case .invalidJSON(let path):
            return "\(path) is not valid JSON; it was left unchanged"
        case .rootNotObject(let path):
            return "\(path) does not hold a JSON object; it was left unchanged"
        case .serversNotObject(let path):
            return "\"mcpServers\" in \(path) is not a JSON object; it was left unchanged"
        case .entryNotObject(let path, let name):
            return "\"mcpServers.\(name)\" in \(path) is not a JSON object; it was left unchanged"
        case .noDefaultConfiguration(let host):
            return "--client \(host.rawValue) has no default configuration file; pass --config PATH with --write"
        case .configurationWithoutWrite:
            return "--config is only used with --write"
        case .executableUnavailable:
            return "the client executable path is unavailable"
        }
    }

    var errorDescription: String? { description }
}

/// A host configuration file that holds servers under "mcpServers", as Claude
/// Code's `.mcp.json` and Cursor's `mcp.json` do. Keys other than the edited
/// entries are kept.
struct AcuaMCPConfigurationDocument {
    static let serversKey = "mcpServers"

    private let path: String
    private var root: [String: Any]
    private(set) var isModified = false

    /// `contents` is nil when the file does not exist yet.
    init(contents: Data?, path: String) throws {
        self.path = path
        guard let contents, !contents.isEmpty else {
            root = [:]
            return
        }

        guard let value = try? JSONSerialization.jsonObject(with: contents) else {
            throw AcuaMCPInstallError.invalidJSON(path: path)
        }

        guard let object = value as? [String: Any] else {
            throw AcuaMCPInstallError.rootNotObject(path: path)
        }

        root = object
    }

    /// Adds or updates each entry. An update replaces only the command and
    /// arguments, so keys the user added to the entry (such as "env") stay.
    mutating func install(_ entries: [AcuaMCPServerEntry]) throws -> [(name: String, change: AcuaMCPConfigurationChange)] {
        var servers = try existingServers()
        var changes: [(name: String, change: AcuaMCPConfigurationChange)] = []

        for entry in entries {
            guard let existing = servers[entry.name] else {
                servers[entry.name] = entry.json
                changes.append((entry.name, .added))
                continue
            }

            guard var existingEntry = existing as? [String: Any] else {
                throw AcuaMCPInstallError.entryNotObject(path: path, name: entry.name)
            }

            let sameCommand = existingEntry[AcuaMCPServerEntry.commandKey] as? String == entry.command
            let sameArguments = existingEntry[AcuaMCPServerEntry.argumentsKey] as? [String] == entry.arguments
            if sameCommand && sameArguments {
                changes.append((entry.name, .unchanged))
                continue
            }

            existingEntry[AcuaMCPServerEntry.commandKey] = entry.command
            existingEntry[AcuaMCPServerEntry.argumentsKey] = entry.arguments
            servers[entry.name] = existingEntry
            changes.append((entry.name, .updated))
        }

        if changes.contains(where: { $0.change != .unchanged }) {
            root[Self.serversKey] = servers
            isModified = true
        }
        return changes
    }

    mutating func uninstall(_ names: [String]) throws -> [(name: String, change: AcuaMCPConfigurationChange)] {
        var servers = try existingServers()
        var changes: [(name: String, change: AcuaMCPConfigurationChange)] = []

        for name in names {
            guard servers.removeValue(forKey: name) != nil else {
                changes.append((name, .absent))
                continue
            }
            changes.append((name, .removed))
        }

        if changes.contains(where: { $0.change == .removed }) {
            root[Self.serversKey] = servers
            isModified = true
        }
        return changes
    }

    func serialized() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(Data("\n".utf8))
        return data
    }

    private func existingServers() throws -> [String: Any] {
        guard let servers = root[Self.serversKey] else { return [:] }
        guard let object = servers as? [String: Any] else {
            throw AcuaMCPInstallError.serversNotObject(path: path)
        }
        return object
    }
}

/// Reads and writes a host configuration file in place.
struct AcuaMCPConfigurationFile {
    let url: URL

    /// nil when the file does not exist.
    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// An atomic write replaces the file, so a symlinked configuration (for
    /// example one kept in a dotfiles repository) is written at its target,
    /// and the previous permissions are put back on the new file.
    func write(_ data: Data) throws {
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        let permissions = try? manager.attributesOfItem(atPath: target.path)[.posixPermissions]

        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)

        guard let permissions else { return }
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }
}

/// What `mcp install` and `mcp uninstall` print: the result on standard
/// output, and hints for the user on standard error so the output stays
/// usable in a pipe.
struct AcuaMCPInstallOutput: Equatable {
    var standardOutput = ""
    var standardError = ""
}

/// `mcp install` and `mcp uninstall`. Without `--write` they only print what
/// to add or remove; with it they edit one configuration file.
struct AcuaMCPInstaller {
    /// Absolute path of the client executable the host will start.
    let command: String
    let home: URL
    let currentDirectory: URL

    func install(host: AcuaMCPHost, servers: [AcuaMCPServer], write: Bool, configuration: String?) throws -> AcuaMCPInstallOutput {
        let entries = uniqueEntries(servers)

        guard write else {
            guard configuration == nil else { throw AcuaMCPInstallError.configurationWithoutWrite }
            return printedInstallation(host: host, entries: entries)
        }

        let file = try configurationFile(host: host, configuration: configuration)
        var document = try AcuaMCPConfigurationDocument(contents: try file.read(), path: file.url.path)
        let changes = try document.install(entries)
        if document.isModified {
            try file.write(try document.serialized())
        }

        return AcuaMCPInstallOutput(standardOutput: report(changes, file: file),
                                    standardError: restartHint(host: host))
    }

    func uninstall(host: AcuaMCPHost, servers: [AcuaMCPServer], write: Bool, configuration: String?) throws -> AcuaMCPInstallOutput {
        let names = uniqueEntries(servers).map(\.name)

        guard write else {
            guard configuration == nil else { throw AcuaMCPInstallError.configurationWithoutWrite }
            return printedUninstallation(host: host, names: names)
        }

        let file = try configurationFile(host: host, configuration: configuration)
        var document = try AcuaMCPConfigurationDocument(contents: try file.read(), path: file.url.path)
        let changes = try document.uninstall(names)
        if document.isModified {
            try file.write(try document.serialized())
        }

        return AcuaMCPInstallOutput(standardOutput: report(changes, file: file),
                                    standardError: restartHint(host: host))
    }

    /// The snippet for hosts configured by a JSON file; the `claude mcp add`
    /// commands for Claude Code, which owns its user-scope configuration.
    private func printedInstallation(host: AcuaMCPHost, entries: [AcuaMCPServerEntry]) -> AcuaMCPInstallOutput {
        if host == .claudeCode {
            let commands = entries.map { entry in
                (["claude", "mcp", "add", "--scope", "user", entry.name, "--"] + [entry.command] + entry.arguments)
                    .map(Self.shellQuoted).joined(separator: " ")
            }
            return AcuaMCPInstallOutput(standardOutput: lines(commands),
                standardError: "Run these commands to add the servers for every project, or rerun with --write to add them to ./.mcp.json.\n")
        }

        let snippet = Self.snippet(entries)
        guard let path = host.defaultConfigurationURL(home: home, currentDirectory: currentDirectory)?.path else {
            return AcuaMCPInstallOutput(standardOutput: snippet,
                standardError: "Add these entries under \"mcpServers\" in your MCP host's configuration, or rerun with --write --config PATH.\n")
        }
        return AcuaMCPInstallOutput(standardOutput: snippet,
            standardError: "Add these entries under \"mcpServers\" in \(path), or rerun with --write.\n")
    }

    private func printedUninstallation(host: AcuaMCPHost, names: [String]) -> AcuaMCPInstallOutput {
        if host == .claudeCode {
            let commands = names.map { name in
                ["claude", "mcp", "remove", "--scope", "user", name].map(Self.shellQuoted).joined(separator: " ")
            }
            return AcuaMCPInstallOutput(standardOutput: lines(commands),
                standardError: "Run these commands to remove the user-scope servers, or rerun with --write to remove them from ./.mcp.json.\n")
        }

        guard let path = host.defaultConfigurationURL(home: home, currentDirectory: currentDirectory)?.path else {
            return AcuaMCPInstallOutput(standardOutput: lines(names),
                standardError: "Remove these entries from \"mcpServers\" in your MCP host's configuration, or rerun with --write --config PATH.\n")
        }
        return AcuaMCPInstallOutput(standardOutput: lines(names),
            standardError: "Remove these entries from \"mcpServers\" in \(path), or rerun with --write.\n")
    }

    private func configurationFile(host: AcuaMCPHost, configuration: String?) throws -> AcuaMCPConfigurationFile {
        // Not URL(fileURLWithPath:relativeTo:): a base without a trailing
        // slash resolves against its parent directory.
        if let configuration {
            let url = configuration.hasPrefix("/")
                ? URL(fileURLWithPath: configuration)
                : currentDirectory.appendingPathComponent(configuration)
            return AcuaMCPConfigurationFile(url: url.standardizedFileURL)
        }

        guard let url = host.defaultConfigurationURL(home: home, currentDirectory: currentDirectory) else {
            throw AcuaMCPInstallError.noDefaultConfiguration(host: host)
        }
        return AcuaMCPConfigurationFile(url: url)
    }

    /// `--server` may repeat a value; each server is configured once, in the
    /// order first given.
    private func uniqueEntries(_ servers: [AcuaMCPServer]) -> [AcuaMCPServerEntry] {
        var seen = Set<AcuaMCPServer>()
        return servers.filter { seen.insert($0).inserted }.map { AcuaMCPServerEntry(server: $0, command: command) }
    }

    private func report(_ changes: [(name: String, change: AcuaMCPConfigurationChange)], file: AcuaMCPConfigurationFile) -> String {
        lines(changes.map { "\($0.name): \($0.change.rawValue) in \(file.url.path)" })
    }

    private func restartHint(host: AcuaMCPHost) -> String {
        "Restart \(host == .generic ? "your MCP host" : host.rawValue) to load the change.\n"
    }

    private func lines(_ values: [String]) -> String {
        values.map { $0 + "\n" }.joined()
    }

    static func snippet(_ entries: [AcuaMCPServerEntry]) -> String {
        let servers = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.json) })
        let object: [String: Any] = [AcuaMCPConfigurationDocument.serversKey: servers]
        // Built from strings and string arrays only, so serialization cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Single-quoted for POSIX shells: the install path holds a space
    /// ("Application Support").
    static func shellQuoted(_ value: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(plain.contains) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
