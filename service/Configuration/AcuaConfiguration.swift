import Foundation

/// User settings read from `~/.acua/config.toml`.
///
/// Every setting has a safe default, so a missing file, an empty file and a
/// missing table all behave the same way. Unknown tables and keys are rejected
/// instead of ignored: a misspelled `deny` must never silently allow an app.
struct AcuaConfiguration: Equatable, Sendable {
    static let defaults = AcuaConfiguration()

    var apps = AcuaAppAccessConfiguration()
    var features = AcuaFeatureConfiguration()
    var screenshots = AcuaScreenshotConfiguration()
    var privacy = AcuaPrivacyConfiguration()
}

enum AcuaAppAccess: String, Sendable, CaseIterable {
    case allow
    case deny
}

/// `[apps]`: which applications the agent may control.
struct AcuaAppAccessConfiguration: Equatable, Sendable {
    /// `false` turns every computer-use request off.
    var enabled = true
    var defaultAccess = AcuaAppAccess.allow
    /// Allowed even when `defaultAccess` is `.deny`.
    var allowedBundleIdentifiers: Set<String> = []
    /// Always denied, whatever `defaultAccess` says.
    var deniedBundleIdentifiers: Set<String> = []
    /// Offer "Always allow" in approval prompts.
    var allowPersistentApproval = true

    func access(forBundleIdentifier bundleIdentifier: String) -> AcuaAppAccess {
        if isDenied(bundleIdentifier) {
            return .deny
        }

        if isExplicitlyAllowed(bundleIdentifier) {
            return .allow
        }

        return defaultAccess
    }

    /// Listed in `allow`. Bundle identifiers compare without case, as Launch
    /// Services resolves them: `deny = ["com.apple.Calculator"]` must block
    /// Calculator, whose identifier is `com.apple.calculator`.
    func isExplicitlyAllowed(_ bundleIdentifier: String) -> Bool {
        Self.contains(allowedBundleIdentifiers, bundleIdentifier)
    }

    func isDenied(_ bundleIdentifier: String) -> Bool {
        Self.contains(deniedBundleIdentifiers, bundleIdentifier)
    }

    private static func contains(_ list: Set<String>, _ bundleIdentifier: String) -> Bool {
        list.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }
}

/// `[features]`: optional behaviors, all off by default.
struct AcuaFeatureConfiguration: Equatable, Sendable {
    /// Let the lock-screen guardian unlock for an approved request.
    var lockedUse = false
    /// Show the hosted picture-in-picture window of the controlled app.
    var remoteHostedPIP = false
}

enum AcuaScreenshotFormat: String, Sendable, CaseIterable {
    case jpeg
    case png
}

/// How many pixels a screenshot has.
enum AcuaScreenshotResolution: String, Sendable, CaseIterable {
    /// One pixel per point, then fitted within 2048 on the long edge and 768
    /// on the short edge, never upscaled. This is the default.
    case fit
    /// Every backing pixel: about 3000 x 1700 for a full Retina window.
    case native
}

/// `[screenshots]`: how captured images are sized and encoded.
struct AcuaScreenshotConfiguration: Equatable, Sendable {
    static let jpegQualityRange: ClosedRange<Double> = 0.01...1.0

    var format = AcuaScreenshotFormat.jpeg
    var jpegQuality = 0.8
    var resolution = AcuaScreenshotResolution.fit
    /// Encoded bytes allowed per screenshot; 0 means no limit. Base64 adds a
    /// third, so the default keeps the image near 1,000,000 bytes in an MCP
    /// result, under the 1 MiB that common clients accept.
    var maxImageBytes = 750_000
}

/// `[privacy]`: sites that are never recorded or captured.
///
/// A domain blocks itself and every subdomain: "bank.example" blocks "login.bank.example" but
/// not "notbank.example".
struct AcuaPrivacyConfiguration: Equatable, Sendable {
    /// Lowercased, without a leading "*." or "." and without a trailing ".".
    var blockedDomains: [String] = []

    func blocks(host: String) -> Bool {
        let normalizedHost = Self.normalize(host)
        return blockedDomains.contains { domain in
            normalizedHost == domain || normalizedHost.hasSuffix("." + domain)
        }
    }

    static func normalize(_ domain: String) -> String {
        var value = domain.lowercased()

        if value.hasPrefix("*.") {
            value.removeFirst(2)
        }

        while value.hasPrefix(".") {
            value.removeFirst()
        }

        while value.hasSuffix(".") {
            value.removeLast()
        }

        return value
    }
}

// MARK: - Decoding

/// A setting that has the right TOML type but an unacceptable value.
struct AcuaInvalidSettingValue: Error {
    let setting: String
    let message: String
}

/// Any key name, so a table can list the keys it does not recognize.
private struct AcuaSettingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

/// Reads one TOML table, rejecting keys it does not know.
private struct AcuaTableReader {
    private let container: KeyedDecodingContainer<AcuaSettingKey>
    private let tablePath: String

    init(_ decoder: any Decoder, allowedKeys: Set<String>) throws {
        container = try decoder.container(keyedBy: AcuaSettingKey.self)
        tablePath = decoder.codingPath.map(\.stringValue).joined(separator: ".")

        let unknownKeys = container.allKeys.map(\.stringValue).filter { !allowedKeys.contains($0) }.sorted()
        guard let firstUnknownKey = unknownKeys.first else {
            return
        }

        throw AcuaInvalidSettingValue(setting: settingPath(firstUnknownKey),
            message: "unknown setting; expected one of: " + allowedKeys.sorted().joined(separator: ", "))
    }

    func settingPath(_ key: String) -> String {
        tablePath.isEmpty ? key : tablePath + "." + key
    }

    func value<Value: Decodable>(_ key: String, default defaultValue: Value) throws -> Value {
        try container.decodeIfPresent(Value.self, forKey: AcuaSettingKey(stringValue: key)) ?? defaultValue
    }

    func choice<Choice: RawRepresentable & CaseIterable>(_ key: String, default defaultValue: Choice) throws -> Choice
        where Choice.RawValue == String {
        guard let text = try container.decodeIfPresent(String.self, forKey: AcuaSettingKey(stringValue: key)) else {
            return defaultValue
        }

        guard let choice = Choice(rawValue: text) else {
            let accepted = Choice.allCases.map { "\"" + $0.rawValue + "\"" }.joined(separator: " or ")
            throw AcuaInvalidSettingValue(setting: settingPath(key), message: "\"\(text)\" is not valid; use \(accepted)")
        }

        return choice
    }
}

extension AcuaConfiguration: Decodable {
    init(from decoder: any Decoder) throws {
        let table = try AcuaTableReader(decoder, allowedKeys: ["apps", "features", "screenshots", "privacy"])

        apps = try table.value("apps", default: AcuaAppAccessConfiguration())
        features = try table.value("features", default: AcuaFeatureConfiguration())
        screenshots = try table.value("screenshots", default: AcuaScreenshotConfiguration())
        privacy = try table.value("privacy", default: AcuaPrivacyConfiguration())
    }
}

extension AcuaAppAccessConfiguration: Decodable {
    init(from decoder: any Decoder) throws {
        let table = try AcuaTableReader(decoder, allowedKeys: [
            "enabled", "default_access", "allow", "deny", "allow_persistent_approval",
        ])

        enabled = try table.value("enabled", default: true)
        defaultAccess = try table.choice("default_access", default: AcuaAppAccess.allow)
        allowedBundleIdentifiers = Set(try table.value("allow", default: [String]()))
        deniedBundleIdentifiers = Set(try table.value("deny", default: [String]()))
        allowPersistentApproval = try table.value("allow_persistent_approval", default: true)

        // Listing an app in both arrays is almost certainly a mistake, so it is
        // reported instead of being resolved by a precedence rule.
        let contradictions = allowedBundleIdentifiers.filter(isDenied).sorted()
        guard contradictions.isEmpty else {
            throw AcuaInvalidSettingValue(setting: table.settingPath("allow"),
                message: "listed in both allow and deny: " + contradictions.joined(separator: ", "))
        }
    }
}

extension AcuaFeatureConfiguration: Decodable {
    init(from decoder: any Decoder) throws {
        let table = try AcuaTableReader(decoder, allowedKeys: ["locked_use", "remote_hosted_pip"])

        lockedUse = try table.value("locked_use", default: false)
        remoteHostedPIP = try table.value("remote_hosted_pip", default: false)
    }
}

extension AcuaScreenshotConfiguration: Decodable {
    init(from decoder: any Decoder) throws {
        let table = try AcuaTableReader(decoder, allowedKeys: ["format", "jpeg_quality", "resolution", "max_image_bytes"])

        format = try table.choice("format", default: AcuaScreenshotFormat.jpeg)
        jpegQuality = try table.value("jpeg_quality", default: 0.8)
        resolution = try table.choice("resolution", default: AcuaScreenshotResolution.fit)
        maxImageBytes = try table.value("max_image_bytes", default: 750_000)

        guard maxImageBytes >= 0 else {
            throw AcuaInvalidSettingValue(setting: table.settingPath("max_image_bytes"),
                message: "\(maxImageBytes) is negative; use 0 for no limit")
        }

        guard Self.jpegQualityRange.contains(jpegQuality) else {
            throw AcuaInvalidSettingValue(setting: table.settingPath("jpeg_quality"),
                message: "\(jpegQuality) is outside \(Self.jpegQualityRange.lowerBound)...\(Self.jpegQualityRange.upperBound)")
        }
    }
}

extension AcuaPrivacyConfiguration: Decodable {
    init(from decoder: any Decoder) throws {
        let table = try AcuaTableReader(decoder, allowedKeys: ["blocked_domains"])
        let configured = try table.value("blocked_domains", default: [String]())

        for domain in configured {
            let normalized = Self.normalize(domain)

            guard !normalized.isEmpty, !normalized.contains("/"), !normalized.contains(":"), !normalized.contains(" ") else {
                throw AcuaInvalidSettingValue(setting: table.settingPath("blocked_domains"),
                    message: "\"\(domain)\" is not a domain name; use a host such as \"bank.example\"")
            }

            blockedDomains.append(normalized)
        }
    }
}
