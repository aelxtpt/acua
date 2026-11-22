import AppKit

/// Set from a request thread to close the dialog unanswered.
final class AcuaAppApprovalDismissal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func request() {
        lock.lock()
        defer { lock.unlock() }
        requested = true
    }
}

/// The service's own approval dialog, shown when the MCP client cannot show an
/// elicitation form. "Deny" is the default button, so Return never grants
/// access by accident.
@MainActor enum AcuaAppApprovalDialog {
    /// An unanswered dialog closes itself and the request is canceled. It is
    /// shorter than the service's default 120 s request deadline, so the
    /// dialog closes before the request fails.
    static let timeoutSeconds: TimeInterval = 110

    /// How often the open dialog checks for a dismissal or its timeout.
    private static let pollSeconds: TimeInterval = 0.25

    static func ask(_ prompt: AcuaAppApprovalPrompt, dismissal: AcuaAppApprovalDismissal) -> AcuaAppApprovalAnswer {
        guard !dismissal.isRequested else { return .dismissed }

        let alert = NSAlert()
        alert.messageText = "Allow the agent to use \(prompt.displayName)?"
        alert.informativeText = prompt.warning
            ?? "An agent connected to Aex Computer Use wants to see and control \(prompt.displayName) (\(prompt.bundleIdentifier)). Allow lasts until the agent disconnects."
        alert.alertStyle = prompt.warning == nil ? .informational : .critical
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: prompt.bundleIdentifier) {
            alert.icon = NSWorkspace.shared.icon(forFile: url.path)
        }

        // Button order fixes the modal responses mapped below.
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        if prompt.offersAlwaysAllow {
            alert.addButton(withTitle: "Always Allow")
        }

        // The service is an accessory app: without this the dialog can open
        // behind the window the user is looking at.
        NSApp.activate()
        alert.window.level = .floating

        // Main-queue blocks do not run inside runModal's loop, so a dismissal
        // is noticed by a timer registered in the modal run-loop mode.
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let watcher = Timer(timeInterval: pollSeconds, repeats: true) { _ in
            guard dismissal.isRequested || ProcessInfo.processInfo.systemUptime >= deadline else { return }
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(watcher, forMode: .modalPanel)
        let response = alert.runModal()
        watcher.invalidate()

        switch response {
        case .alertFirstButtonReturn: return .deny
        case .alertSecondButtonReturn: return .allowForSession
        case .alertThirdButtonReturn: return .alwaysAllow
        default: return .dismissed
        }
    }
}
