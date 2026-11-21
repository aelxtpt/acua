import Foundation

// Unit tests for ~/.acua/config.toml loading and the local application policy.
// They only touch a private temporary directory; no service is started.

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acua-configuration-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ text: String, named name: String = AcuaConfigurationLocation.fileName) throws -> URL {
        let file = url.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@main
enum AcuaConfigurationTests {
    private static var passed = 0

    private static func check(_ name: String, _ condition: Bool) {
        precondition(condition, name)
        passed += 1
        print("PASS \(name)")
    }

    private static func loadingError(_ text: String, in directory: TemporaryDirectory) throws -> AcuaConfigurationError? {
        let file = try directory.write(text)

        do {
            _ = try AcuaConfigurationLoader(fileURL: file).load()
            return nil
        } catch let error as AcuaConfigurationError {
            return error
        }
    }

    private static func settingName(of error: AcuaConfigurationError?) -> String? {
        guard case .invalidSetting(_, let setting, _)? = error else {
            return nil
        }

        return setting
    }

    static func main() throws {
        try locationTests()
        try loadingTests()
        try validationTests()
        try policyTests()
        try privacyTests()
        print("PASS \(passed) ACUA configuration checks")
    }

    private static func locationTests() throws {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

        let defaultFile = AcuaConfigurationLocation.fileURL(environment: [:], homeDirectory: home)
        check("FileURL_NoAcuaHome_UsesDotAcuaInHome", defaultFile.path == "/Users/someone/.acua/config.toml")

        let overridden = AcuaConfigurationLocation.fileURL(environment: ["ACUA_HOME": "/private/tmp/acua-home"], homeDirectory: home)
        check("FileURL_AcuaHomeSet_UsesAcuaHomeDirectory", overridden.path == "/private/tmp/acua-home/config.toml")

        let empty = AcuaConfigurationLocation.fileURL(environment: ["ACUA_HOME": ""], homeDirectory: home)
        check("FileURL_AcuaHomeEmpty_FallsBackToDotAcua", empty.path == "/Users/someone/.acua/config.toml")
    }

    private static func loadingTests() throws {
        let directory = try TemporaryDirectory()

        let missing = directory.url.appendingPathComponent("absent/config.toml")
        check("Load_FileMissing_ReturnsDefaults", try AcuaConfigurationLoader(fileURL: missing).load() == .defaults)
        check("Load_FileMissing_DoesNotCreateFile", !FileManager.default.fileExists(atPath: missing.path))

        let empty = try directory.write("")
        check("Load_EmptyFile_ReturnsDefaults", try AcuaConfigurationLoader(fileURL: empty).load() == .defaults)

        let defaults = AcuaConfiguration.defaults
        check("Defaults_Apps_AllowEveryAppWithPersistentApproval",
                  defaults.apps.enabled && defaults.apps.defaultAccess == .allow && defaults.apps.allowPersistentApproval)
        check("Defaults_Features_AreAllOff",
                  !defaults.features.lockedUse && !defaults.features.remoteHostedPIP)
        check("Defaults_Screenshots_UseJPEGAtEightyPercent",
                  defaults.screenshots.format == .jpeg && defaults.screenshots.jpegQuality == 0.8)

        let complete = try directory.write("""
            [apps]
            enabled = false
            default_access = "deny"
            allow = ["com.apple.TextEdit"]
            deny = ["com.apple.Terminal"]
            allow_persistent_approval = false

            [features]
            locked_use = true
            remote_hosted_pip = true

            [screenshots]
            format = "png"
            jpeg_quality = 0.5
            """)
        let loaded = try AcuaConfigurationLoader(fileURL: complete).load()
        check("Load_CompleteFile_ReadsApps",
                  !loaded.apps.enabled && loaded.apps.defaultAccess == .deny &&
                  loaded.apps.allowedBundleIdentifiers == ["com.apple.TextEdit"] &&
                  loaded.apps.deniedBundleIdentifiers == ["com.apple.Terminal"] && !loaded.apps.allowPersistentApproval)
        check("Load_CompleteFile_ReadsFeatures",
                  loaded.features.lockedUse && loaded.features.remoteHostedPIP)
        check("Load_CompleteFile_ReadsScreenshots", loaded.screenshots.format == .png && loaded.screenshots.jpegQuality == 0.5
                  && loaded.screenshots.resolution == .native && loaded.screenshots.maxImageBytes == 0)

        let partial = try directory.write("""
            [apps]
            deny = ["com.apple.Terminal"]
            """)
        let partiallyLoaded = try AcuaConfigurationLoader(fileURL: partial).load()
        check("Load_PartialTable_KeepsDefaultsForMissingKeys",
                  partiallyLoaded.apps.enabled && partiallyLoaded.apps.defaultAccess == .allow &&
                  partiallyLoaded.features == .init() && partiallyLoaded.screenshots == .init())
    }

    private static func validationTests() throws {
        let directory = try TemporaryDirectory()

        guard case .invalidSyntax(_, let line, _, _)? = try loadingError("[apps]\nenabled = \n", in: directory) else {
            preconditionFailure("Load_InvalidSyntax_ThrowsInvalidSyntax")
        }
        check("Load_InvalidSyntax_ReportsTheLine", line == 2)

        let unknownKey = try loadingError("[apps]\ndefualt_access = \"deny\"\n", in: directory)
        check("Load_MisspelledKey_IsRejectedInsteadOfIgnored", unknownKey?.description.contains("apps.defualt_access") == true)

        let unknownTable = try loadingError("[app]\ndeny = [\"com.apple.Terminal\"]\n", in: directory)
        check("Load_UnknownTable_IsRejected", settingName(of: unknownTable) == "app")

        let badAccess = try loadingError("[apps]\ndefault_access = \"maybe\"\n", in: directory)
        check("Load_UnknownAccessValue_IsRejected", settingName(of: badAccess) == "apps.default_access")

        let wrongType = try loadingError("[features]\nlocked_use = \"yes\"\n", in: directory)
        check("Load_WrongValueType_IsRejected", wrongType?.description.contains("features.locked_use") == true)

        let quality = try loadingError("[screenshots]\njpeg_quality = 1.5\n", in: directory)
        check("Load_JPEGQualityOutOfRange_IsRejected", quality?.description.contains("screenshots.jpeg_quality") == true)

        let zeroQuality = try loadingError("[screenshots]\njpeg_quality = 0.0\n", in: directory)
        check("Load_JPEGQualityZero_IsRejected", settingName(of: zeroQuality) == "screenshots.jpeg_quality")

        let contradiction = try loadingError("[apps]\nallow = [\"com.apple.Notes\"]\ndeny = [\"com.apple.Notes\"]\n", in: directory)
        check("Load_SameAppAllowedAndDenied_IsRejected", contradiction?.description.contains("com.apple.Notes") == true)

        let unreadable = directory.url.appendingPathComponent("directory-not-file", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        do {
            _ = try AcuaConfigurationLoader(fileURL: unreadable).load()
            preconditionFailure("Load_PathIsDirectory_Throws")
        } catch AcuaConfigurationError.unreadable {
            check("Load_PathIsDirectory_ThrowsUnreadable", true)
        }
    }

    private static func privacyTests() throws {
        let directory = try TemporaryDirectory()

        check("Defaults_Privacy_BlocksNoDomain", AcuaConfiguration.defaults.privacy.blockedDomains.isEmpty)

        let file = try directory.write("""
            [privacy]
            blocked_domains = ["Bank.example", "*.health.example", "mail.example."]
            """)
        let privacy = try AcuaConfigurationLoader(fileURL: file).load().privacy
        check("Load_BlockedDomains_AreNormalizedToLowercaseWithoutWildcard",
              privacy.blockedDomains == ["bank.example", "health.example", "mail.example"])

        check("Blocks_ExactHost_IsBlocked", privacy.blocks(host: "bank.example"))
        check("Blocks_Subdomain_IsBlocked", privacy.blocks(host: "login.BANK.example"))
        check("Blocks_HostWithTrailingDot_IsBlocked", privacy.blocks(host: "bank.example."))
        check("Blocks_LookalikeSuffix_IsNotBlocked", !privacy.blocks(host: "notbank.example"))
        check("Blocks_ParentDomain_IsNotBlocked", !privacy.blocks(host: "example"))
        check("Blocks_UnrelatedHost_IsNotBlocked", !privacy.blocks(host: "news.example"))

        let withScheme = try loadingError("[privacy]\nblocked_domains = [\"https://bank.example\"]\n", in: directory)
        check("Load_BlockedDomainWithScheme_IsRejected", settingName(of: withScheme) == "privacy.blocked_domains")

        let withPath = try loadingError("[privacy]\nblocked_domains = [\"bank.example/login\"]\n", in: directory)
        check("Load_BlockedDomainWithPath_IsRejected", settingName(of: withPath) == "privacy.blocked_domains")

        let empty = try loadingError("[privacy]\nblocked_domains = [\"*.\"]\n", in: directory)
        check("Load_BlockedDomainEmptyAfterNormalizing_IsRejected", settingName(of: empty) == "privacy.blocked_domains")
    }

    private static func policyTests() throws {
        var apps = AcuaAppAccessConfiguration()
        let open = ComputerUsePolicy(configuration: AcuaConfiguration(apps: apps))
        check("Policy_DefaultConfiguration_AllowsAnyApp", open.enabled && open.allows("com.apple.TextEdit"))

        apps.deniedBundleIdentifiers = ["com.apple.Terminal"]
        let denying = ComputerUsePolicy(configuration: AcuaConfiguration(apps: apps))
        check("Policy_DenyList_DeniesListedApp", !denying.allows("com.apple.Terminal"))
        check("Policy_DenyList_StillAllowsOtherApps", denying.allows("com.apple.TextEdit"))

        apps = AcuaAppAccessConfiguration(defaultAccess: .deny, allowedBundleIdentifiers: ["com.apple.TextEdit"])
        let closed = ComputerUsePolicy(configuration: AcuaConfiguration(apps: apps))
        check("Policy_DefaultDeny_AllowsOnlyAllowList", closed.allows("com.apple.TextEdit") && !closed.allows("com.apple.Notes"))

        apps = AcuaAppAccessConfiguration(enabled: false)
        let disabled = ComputerUsePolicy(configuration: AcuaConfiguration(apps: apps))
        check("Policy_Disabled_DeniesEveryApp", !disabled.enabled && !disabled.allows("com.apple.TextEdit"))

        apps = AcuaAppAccessConfiguration(allowPersistentApproval: false)
        let noPersistence = ComputerUsePolicy(configuration: AcuaConfiguration(apps: apps))
        check("Policy_PersistentApprovalOff_IsReported", !noPersistence.allowPersistentApproval)
    }
}
