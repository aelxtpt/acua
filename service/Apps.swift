import AppKit
import ApplicationServices

struct ResolvedApp {
    let running: NSRunningApplication
    let bundleIdentifier: String
    let displayName: String
    let appPath: String?
    var ipc: IPCApp { IPCApp(pid: running.processIdentifier, bundleIdentifier: bundleIdentifier, appPath: appPath) }
}

enum AppResolver {
    static func processKey(_ app: NSRunningApplication) -> String {
        "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
    }
    static func resolve(_ identifier: String) -> ResolvedApp? {
        try? find(identifier)
    }

    /// Match exact aliases before partial names; never select the first of
    /// several candidates, even when the identifier matches multiple processes.
    static func match(_ identifier: String, aliases: [[String]]) throws -> Int? {
        let query = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ServiceError(.invalidApp, "Application identifier is required") }
        let lowered = query.lowercased()
        let tiers: [(String) -> Bool] = [
            { $0 == query }, { $0.lowercased() == lowered },
            { $0.lowercased().contains(lowered) },
        ]
        for predicate in tiers {
            let hits = aliases.indices.filter { aliases[$0].contains(where: predicate) }
            if hits.count > 1 { throw ServiceError(.ambiguousApp, "Ambiguous application '\(query)'; use a unique bundle identifier or path") }
            if let index = hits.first { return index }
        }
        return nil
    }

    static func require(_ identifier: String) throws -> ResolvedApp {
        guard let app = try find(identifier) else {
            throw ServiceError(.runningApplicationNotFound, "Running application not found for '\(identifier)'")
        }
        return app
    }

    static func find(_ identifier: String) throws -> ResolvedApp? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        let aliases: [[String]] = running.map { app in
            var names = [app.bundleIdentifier, app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
            // The policy layer hands back `target.appPath`, so accept absolute bundle paths too.
            if let bundleURL = app.bundleURL {
                names += [bundleURL.path, bundleURL.lastPathComponent,
                          bundleURL.deletingPathExtension().lastPathComponent,
                          bundleURL.resolvingSymlinksInPath().path]
            }
            return names
        }
        guard let index = try match(identifier, aliases: aliases) else { return nil }
        return wrap(running[index], identifier)
    }

    private static func wrap(_ app: NSRunningApplication, _ identifier: String) -> ResolvedApp {
        ResolvedApp(
            running: app,
            bundleIdentifier: app.bundleIdentifier ?? identifier,
            displayName: app.localizedName ?? identifier,
            appPath: app.bundleURL?.path
        )
    }

    static func pid(for identifier: String) throws -> pid_t {
        try require(identifier).running.processIdentifier
    }

    static func activate(_ identifier: String) throws {
        try NativeTargetPolicy.requireAllowed(identifier)
        let resolved = try find(identifier)
        if let resolved { try NativeTargetPolicy.requireAllowed(resolved.bundleIdentifier) }
        try Permissions.requireUnlockedScreen()
        if let resolved {
            resolved.running.activate(options: [.activateAllWindows])
            return
        }
        try launch(identifier)
    }

    /// Launch an app that is not running yet (bundle identifier or bundle/display name).
    static func launch(_ identifier: String) throws {
        _ = try match(identifier, aliases: [])
        try RequestRuntime.check()
        var url: URL?
        if identifier.hasPrefix("/"), identifier.hasSuffix(".app"), FileManager.default.fileExists(atPath: identifier) {
            url = URL(fileURLWithPath: identifier)
        }
        if url == nil && identifier.contains(".") {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
        if url == nil { url = locateByName(identifier) }
        guard let appURL = url else {
            throw ServiceError(.invalidApp, "Application not found for '\(identifier)'")
        }
        if let bundleID = Bundle(url: appURL)?.bundleIdentifier { try NativeTargetPolicy.requireAllowed(bundleID) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        try RequestRuntime.wait(for: semaphore, maximumSeconds: 30)
        if let launchError {
            throw ServiceError(.invalidApp, "Failed to launch '\(identifier)': \(launchError.localizedDescription)")
        }
        // Wait (briefly) until the process shows up as running.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try find(identifier) != nil { return }
            try RequestRuntime.wait(0.1)
        }
        throw ServiceError(.runningApplicationNotFound, "Launched application did not become available")
    }

    static func targetIdentifier(_ identifier: String) throws -> String {
        _ = try match(identifier, aliases: [])
        if let app = try find(identifier) { return app.bundleIdentifier }
        let url: URL?
        if identifier.hasPrefix("/"), identifier.hasSuffix(".app") { url = URL(fileURLWithPath: identifier) }
        else { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) ?? locateByName(identifier) }
        guard let url, let bundle = Bundle(url: url)?.bundleIdentifier else { throw ServiceError(.invalidApp, "Application target not found") }
        return bundle
    }

    private static func locateByName(_ name: String) -> URL? {
        let candidates = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            "/Applications/Utilities/\(name).app",
        ]
        if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        return nil
    }
}

enum Policy {
    struct Target {
        let bundleIdentifier: String
        let displayName: String
        let appPath: String
    }

    // Resolve an installed application target before obtaining policy. A missing app is a lookup error, not a forbidden app.
    static func target(for identifier: String) throws -> Target {
        func fromPath(_ path: String) -> Target? {
            guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return Target(bundleIdentifier: id, displayName: name, appPath: url.path)
        }
        if let target = fromPath(identifier) { return target }
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
        if urls.count > 1 {
            throw ServiceError(.ambiguousApp, "Ambiguous application '\(identifier)'; use a unique path")
        }
        if let url = urls.first, let target = fromPath(url.path) { return target }
        if let path = NSWorkspace.shared.fullPath(forApplication: identifier), let target = fromPath(path) { return target }
        throw ServiceError(.invalidApp, "Invalid app: \(identifier)")
    }

    static func decision(for identifier: String, policy: ComputerUsePolicy = .defaults) throws -> JSON {
        render(target: try target(for: identifier), policy: policy)
    }

    static func render(target resolved: Target, policy: ComputerUsePolicy) -> JSON {
        let highRisk = ApplicationPolicyRisk.isHigh(bundleID: resolved.bundleIdentifier,
            urlTypes: Bundle(path: resolved.appPath)?.object(forInfoDictionaryKey: "CFBundleURLTypes"))
        var descriptor: JSON = ["bundleIdentifier": resolved.bundleIdentifier, "displayName": resolved.displayName,
            "appPath": resolved.appPath, "risk": highRisk ? "high" : "low"]
        if highRisk { descriptor["warningSubtitle"] = ApplicationPolicyRisk.warning }
        return [
            "decision": !policy.allows(resolved.bundleIdentifier) ? "denied" :
                (NativeTargetPolicy.isForbidden(resolved.bundleIdentifier) ? "forbidden" : "allowed"),
            "target": descriptor,
            "allowPersistentApproval": policy.allowPersistentApproval,
        ]
    }
}

enum Permissions {
    static func screenLocked() -> Bool {
        !ScreenLockState.read().interactionAvailable
    }
    static func requireUnlockedScreen() throws {
        let state = ScreenLockState.read()
        guard state.interactionAvailable else {
            let message = state.state == .locked
                ? "The macOS session is locked; unlock it before interacting with applications"
                : "The current macOS console session is unavailable; cannot confirm an unlocked desktop"
            throw ServiceError(.screenLocked, message)
        }
    }
    static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }
    static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
    @discardableResult
    static func requestAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    static func requireAccessibility() throws {
        guard accessibilityGranted() else {
            throw ServiceError(.permissionsNotGranted, "Accessibility permission is required for Computer Use")
        }
    }
    static func requireScreenRecording() throws {
        guard screenRecordingGranted() else {
            requestScreenRecording()
            throw ServiceError(.permissionsPending, "Screen Recording permission is required for Computer Use")
        }
    }
}
