import Foundation
import CUAToml

/// Where `config.toml` lives: `$ACUA_HOME/config.toml`, or `~/.acua/config.toml`.
enum AcuaConfigurationLocation {
    static let homeEnvironmentVariable = "ACUA_HOME"
    static let defaultDirectoryName = ".acua"
    static let fileName = "config.toml"

    /// `$ACUA_HOME`, or `~/.acua`. Also holds local data such as Timeline history.
    static func directoryURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let override = environment[homeEnvironmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return homeDirectory.appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    static func fileURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directoryURL(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

enum AcuaConfigurationError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case invalidSyntax(path: String, line: Int, column: Int, message: String)
    case invalidSetting(path: String, setting: String, message: String)

    var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "Cannot read \(path): \(reason)"
        case .invalidSyntax(let path, let line, let column, let message):
            return "\(path):\(line):\(column): invalid TOML: \(message)"
        case .invalidSetting(let path, let setting, let message):
            return "\(path): \(setting): \(message)"
        }
    }
}

/// Reads the configuration file. It never creates or rewrites the file.
struct AcuaConfigurationLoader {
    let fileURL: URL

    init(fileURL: URL = AcuaConfigurationLocation.fileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> AcuaConfiguration {
        let path = fileURL.path

        guard FileManager.default.fileExists(atPath: path) else {
            return .defaults
        }

        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw AcuaConfigurationError.unreadable(path: path, reason: error.localizedDescription)
        }

        do {
            return try TOMLDecoder().decode(AcuaConfiguration.self, from: text)
        } catch let error as AcuaInvalidSettingValue {
            throw AcuaConfigurationError.invalidSetting(path: path, setting: error.setting, message: error.message)
        } catch let error as TOMLDecodingError {
            throw Self.configurationError(from: error, path: path)
        } catch let error as DecodingError {
            throw Self.configurationError(from: error, path: path)
        }
    }

    private static func settingPath(_ codingPath: [any CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }

    private static func configurationError(from error: TOMLDecodingError, path: String) -> AcuaConfigurationError {
        switch error {
        case .invalidSyntax(let line, let column, let message):
            return .invalidSyntax(path: path, line: line, column: column, message: message)
        case .typeMismatch(let expected, let found, let codingPath):
            return .invalidSetting(path: path, setting: settingPath(codingPath), message: "expected \(expected), found \(found)")
        case .valueNotFound(let type, let codingPath):
            return .invalidSetting(path: path, setting: settingPath(codingPath), message: "missing \(type) value")
        case .dataCorrupted(let message, let codingPath):
            return .invalidSetting(path: path, setting: settingPath(codingPath), message: message)
        case .keyNotFound(let key, _):
            return .invalidSetting(path: path, setting: key.stringValue, message: "required setting is missing")
        case .invalidData(let message):
            return .unreadable(path: path, reason: message)
        }
    }

    private static func configurationError(from error: DecodingError, path: String) -> AcuaConfigurationError {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return .invalidSetting(path: path, setting: settingPath(context.codingPath), message: context.debugDescription)
        case .keyNotFound(let key, let context):
            return .invalidSetting(path: path, setting: settingPath(context.codingPath + [key]), message: "required setting is missing")
        @unknown default:
            return .invalidSetting(path: path, setting: "", message: String(describing: error))
        }
    }
}
