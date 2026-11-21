import AppKit
import Darwin

/// Finds, and when asked launches, the Aex Computer Use service that this
/// helper belongs to. Only ACUA's own bundle identifiers are ever targeted.
enum CodexRunningService {
    static let ownBundleIdentifier = "com.aex.computeruse"

    /// `com.aex.computeruse` itself or one of its dotted children.
    static func isOwnServiceIdentifier(_ identifier: String) -> Bool {
        identifier == ownBundleIdentifier || identifier.hasPrefix(ownBundleIdentifier + ".")
    }

    struct Candidate {
        let processIdentifier: pid_t
        let bundleURL: URL?
    }

    /// The first running instance whose bundle is the expected installation.
    static func preferredPID(_ candidates: [Candidate], expected: URL) -> pid_t? {
        candidates.first { $0.bundleURL?.standardizedFileURL == expected.standardizedFileURL }?.processIdentifier
    }

    private static func expectedURL(serviceBundleIdentifier: String, mainBundle: Bundle,
                                    environment: [String: String], home: URL) -> URL? {
        guard isOwnServiceIdentifier(serviceBundleIdentifier) else { return nil }
        if mainBundle.bundleIdentifier == serviceBundleIdentifier { return mainBundle.bundleURL }
        // The helper ships inside the service application. Prefer that
        // containing application, wherever it is installed, over the default
        // installation directory below.
        if serviceBundleIdentifier == ownBundleIdentifier,
           mainBundle.bundleIdentifier == "com.aex.computeruse.client" {
            let helper = mainBundle.bundleURL.standardizedFileURL
            let support = helper.deletingLastPathComponent()
            let contents = support.deletingLastPathComponent()
            let service = contents.deletingLastPathComponent()
            if helper.lastPathComponent == "AexComputerUseClient.app",
               support.lastPathComponent == "SharedSupport", contents.lastPathComponent == "Contents",
               service.pathExtension == "app", Bundle(url: service)?.bundleIdentifier == serviceBundleIdentifier {
                return service
            }
        }
        let candidate = AexInstallDirectory.url(environment: environment, homeDirectoryURL: home)
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("Aex Computer Use.app", isDirectory: true)
        guard Bundle(url: candidate)?.bundleIdentifier == serviceBundleIdentifier else { return nil }
        return candidate
    }

    @MainActor private static func running(
        expected: URL, serviceBundleIdentifier: String,
        runningApplications: (String) -> [NSRunningApplication],
        application: (pid_t) -> NSRunningApplication?
    ) -> NSRunningApplication? {
        let candidates = runningApplications(serviceBundleIdentifier).map {
            Candidate(processIdentifier: $0.processIdentifier, bundleURL: $0.bundleURL)
        }
        return preferredPID(candidates, expected: expected).flatMap(application)
    }

    // The notification path deliberately never launches the service.
    @MainActor static func find(
        serviceBundleIdentifier: String, mainBundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runningApplications: (String) -> [NSRunningApplication] = NSRunningApplication.runningApplications,
        application: (pid_t) -> NSRunningApplication? = NSRunningApplication.init(processIdentifier:)
    ) -> NSRunningApplication? {
        guard let expected = expectedURL(serviceBundleIdentifier: serviceBundleIdentifier, mainBundle: mainBundle,
                                         environment: environment, home: home) else { return nil }
        return running(expected: expected, serviceBundleIdentifier: serviceBundleIdentifier,
                       runningApplications: runningApplications, application: application)
    }

    typealias OpenCompletion = @Sendable (NSRunningApplication?, (any Swift.Error)?) -> Void
    typealias Opener = @MainActor (URL, NSWorkspace.OpenConfiguration, @escaping OpenCompletion) -> Void

    @MainActor static func open(_ url: URL, configuration: NSWorkspace.OpenConfiguration,
                               completion: @escaping OpenCompletion) {
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: completion)
    }

    @MainActor static func resolve(
        serviceBundleIdentifier: String, launchIfNeeded: Bool,
        mainBundle: Bundle = .main,
        environment: () -> [String: String] = { ProcessInfo.processInfo.environment },
        home: () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        runningApplications: (String) -> [NSRunningApplication] = NSRunningApplication.runningApplications,
        application: (pid_t) -> NSRunningApplication? = NSRunningApplication.init(processIdentifier:),
        opener: Opener = open
    ) async throws -> NSRunningApplication? {
        // Both providers are read even when the main bundle is the runtime app.
        let initialEnvironment = environment()
        let initialHome = home()
        guard let expected = expectedURL(serviceBundleIdentifier: serviceBundleIdentifier, mainBundle: mainBundle,
                                         environment: initialEnvironment, home: initialHome) else {
            if launchIfNeeded { throw ComputerUseIPCClient.Error.couldNotFindServiceApp }
            return nil
        }
        if let existing = running(expected: expected, serviceBundleIdentifier: serviceBundleIdentifier,
                                  runningApplications: runningApplications, application: application) {
            return existing
        }
        guard launchIfNeeded else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Read the environment again at the launch boundary so the service
        // gets the client's current values. ACUA_HOME is forwarded too, so a
        // service launched for a client reads the same ~/.acua/config.toml.
        let forwarded = ["CODEX_HOME", AexInstallDirectory.environmentVariable, "ACUA_HOME"].compactMap { key in
            environment()[key].flatMap { $0.isEmpty ? nil : (key, $0) }
        }
        if !forwarded.isEmpty {
            configuration.environment = Dictionary(uniqueKeysWithValues: forwarded)
        }
        return try await withCheckedThrowingContinuation { continuation in
            opener(expected, configuration) { application, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    precondition(application != nil, "NSWorkspace returned neither an application nor an error")
                    continuation.resume(returning: application!)
                }
            }
        }
    }
}

/// Default installation root of Aex Computer Use (matches `make install`'s
/// SERVICE_DIR). `AEX_COMPUTER_USE_HOME` selects another root. Discovery
/// never looks inside an agent's own configuration directory.
enum AexInstallDirectory {
    static let environmentVariable = "AEX_COMPUTER_USE_HOME"
    static func url(environment: [String: String], homeDirectoryURL: URL) -> URL {
        if let configured = environment[environmentVariable], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return homeDirectoryURL.appendingPathComponent("Library/Application Support/Aex Computer Use", isDirectory: true)
    }
}
