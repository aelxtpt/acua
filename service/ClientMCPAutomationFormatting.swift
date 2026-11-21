import Foundation
import MCP

enum AutomationMCPFormatting {
    static func bundleBuildVersion(_ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    static func appStateText(_ result: ComputerUseIPCAppSnapshotResult) -> String {
        let app = result.app
        return "App=\(app.appPath ?? app.bundleIdentifier) (bundleID \(app.bundleIdentifier), pid \(app.pid))\n" + result.appSnapshot.text
    }

    static func stateText(_ result: ComputerUseIPCAppSnapshotResult, includeInstructions: Bool, bundle: Bundle = .main) -> String {
        var text = "Computer Use state (CUA App Version: \(bundleBuildVersion(bundle) ?? "0"))"
        if includeInstructions, let instructions = result.appSpecificInstructions, !instructions.isEmpty {
            text += "\n<app_specific_instructions>\n" + instructions + "\n</app_specific_instructions>"
        }
        return text + "\n<app_state>\n" + appStateText(result) + "\n</app_state>"
    }

    static func actionText(_ result: ComputerUseIPCActionResult) -> String {
        let header = "App=\(result.app.bundleIdentifier) (pid \(result.app.pid))\n"
        if let appSnapshot = result.appSnapshot { return header + appSnapshot.text }
        return header + "Action completed. Call `get_app_state` to fetch the updated UI state."
    }

    static func appLine(_ app: ComputerUseIPCDiscoveredApp, formatter: DateFormatter) -> String {
        var flags: [String] = []
        if app.isFrontmost { flags.append("frontmost") }
        if app.isRunning { flags.append("running") }
        if let date = app.lastUsedDate { flags.append("last-used=" + formatter.string(from: date)) }
        if let count = app.useCount, count >= 1 { flags.append("uses=\(count)") }
        let suffix = flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]"
        let path = app.appPath.map { " — " + $0 } ?? ""
        return app.displayName + path + " — " + app.bundleIdentifier + suffix
    }

    static func appsText(_ apps: [ComputerUseIPCDiscoveredApp]) -> String {
        guard !apps.isEmpty else { return "No apps found." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return apps.map { appLine($0, formatter: formatter) }.joined(separator: "\n")
    }

    static func result(text: String, screenshot: ComputerUseIPCScreenshot?,
                       read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> CallTool.Result {
        var content: [Tool.Content] = [.text(text)]
        if let screenshot, let data = try? read(screenshot.url) {
            content.append(.image(data: data.base64EncodedString(), mimeType: screenshot.mimeType, metadata: nil))
        }
        return .init(content: content)
    }

    static func apps(_ apps: [ComputerUseIPCDiscoveredApp]) -> CallTool.Result {
        result(text: appsText(apps), screenshot: nil)
    }
    static func state(_ result: ComputerUseIPCAppSnapshotResult, includeInstructions: Bool, bundle: Bundle = .main,
                      read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> CallTool.Result {
        self.result(text: stateText(result, includeInstructions: includeInstructions, bundle: bundle),
            screenshot: result.appSnapshot.screenshot, read: read)
    }
    static func state(_ result: ComputerUseIPCAppSnapshotResult, deliveryState: AppInstructionDeliveryState,
                      bundle: Bundle = .main,
                      read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) async -> CallTool.Result {
        let include = await deliveryState.shouldIncludeInstructions(for: result.app.bundleIdentifier)
        return state(result, includeInstructions: include, bundle: bundle, read: read)
    }
    static func action(_ result: ComputerUseIPCActionResult,
                       read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> CallTool.Result {
        self.result(text: actionText(result), screenshot: result.appSnapshot?.screenshot, read: read)
    }
}

/// Insertion precedes formatting and is remembered even when instructions are
/// empty or absent, through this per-server actor's Set insertion.
actor AppInstructionDeliveryState {
    private var bundleIdentifiersWithDeliveredInstructions = Set<String>()
    func shouldIncludeInstructions(for bundleIdentifier: String) -> Bool {
        bundleIdentifiersWithDeliveredInstructions.insert(bundleIdentifier).inserted
    }
}
