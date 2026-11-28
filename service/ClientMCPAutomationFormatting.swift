import Foundation
import MCP

enum AutomationMCPFormatting {
    static func bundleBuildVersion(_ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// The standard buttons every titled window has. They are part of the
    /// window, not of what the app shows inside it.
    static let windowChromeRoles = ["close button", "full screen button", "minimize button", "zoom button"]

    static let emptyWindowExplanation = "this window's accessibility tree has no content elements, only the window and its "
        + "standard buttons. The app has not published its UI tree. Apps that build the tree only when they draw a frame "
        + "(GPUI/AccessKit apps, for example) do this just after launch and while their window is not being redrawn, and "
        + "then the screenshot can be out of date too. Call `get_app_state` again; if the tree stays empty, ask the user "
        + "to bring the app's window to the front."

    /// True when the tree shows a window and nothing inside any window except
    /// its standard buttons. Tree lines are "<tabs><index> <role> <title>";
    /// the menu bar and any line that is not an element are ignored.
    static func windowHasNoContent(_ tree: String) -> Bool {
        var sawWindow = false, insideMenuBar = false
        for line in tree.split(separator: "\n", omittingEmptySubsequences: true) {
            let depth = line.prefix { $0 == "\t" }.count
            let body = line.dropFirst(depth)
            let index = body.prefix { $0.isASCII && $0.isNumber }
            guard !index.isEmpty, body.dropFirst(index.count).first == " " else { continue }
            let role = body.dropFirst(index.count + 1)
            if depth == 0 {
                insideMenuBar = role.hasPrefix("menu bar")
                if !insideMenuBar { sawWindow = true }
            } else if !insideMenuBar, !windowChromeRoles.contains(where: { role.hasPrefix($0) }) {
                return false
            }
        }
        return sawWindow
    }

    static func emptyWindowWarning(_ tree: String, afterAction: Bool) -> String? {
        guard windowHasNoContent(tree) else { return nil }
        if afterAction {
            return "Warning: the action was sent, but its effect cannot be confirmed: " + emptyWindowExplanation
                + " Do not repeat the action before the tree is back: it may already have taken effect."
        }
        return "Warning: " + emptyWindowExplanation
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
        text += "\n<app_state>\n" + appStateText(result) + "\n</app_state>"
        if let warning = emptyWindowWarning(result.appSnapshot.text, afterAction: false) { text += "\n" + warning }
        return text
    }

    static func actionText(_ result: ComputerUseIPCActionResult) -> String {
        let header = "App=\(result.app.bundleIdentifier) (pid \(result.app.pid))\n"
        if let appSnapshot = result.appSnapshot {
            guard let warning = emptyWindowWarning(appSnapshot.text, afterAction: true) else { return header + appSnapshot.text }
            return header + appSnapshot.text + "\n" + warning
        }
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
