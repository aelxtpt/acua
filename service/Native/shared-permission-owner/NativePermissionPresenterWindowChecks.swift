import AppKit
import SwiftUI
import Foundation

private final class PermissionPresenterWindowFailure: Error, @unchecked Sendable {}

@MainActor enum NativePermissionPresenterWindowChecks {
    static func runWindow(output: URL) async throws -> Int32 {
        var cases = [[String: Any]]()
        func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let settings = SettingsAccessoryNativeBinding<NSImage>(isScreenRecording: { $0.identifier == "system_settings_Privacy_ScreenCapture" },
            preventActivation: { _ in preconditionFailure("No Settings activation") }, reenableActivation: { preconditionFailure("No Settings activation") },
            makeWindow: { _, _, _ in preconditionFailure("No Settings accessory") }, makeTransition: { preconditionFailure("No Settings transition") })
        var ownedCloses = 0
        for source in [ServicePermissionSource.computerUse, .appshot, .timeline] {
            var presenter: NativeAppshotPermissions.AppshotPresenter? = .init(binding: settings,
                configuration: .init(source: source, onRequestFinished: { _, _ in }, onClose: { ownedCloses += 1 }),
                status: { _ in .authorized })
            weak let weakPresenter = presenter
            let window = presenter!.window
            guard let host = window.host.controller.window,
                  host.contentView is NSHostingView<PermissionWindowContent> else { throw PermissionPresenterWindowFailure() }
            check("shared native presenter builds source-specific catalogue \(source)", window.catalog.requestSource.rawValue == PermissionWindowServiceAdapter.windowSource(source).rawValue && window.coordinator.catalogSource.rawValue == window.catalog.requestSource.rawValue)
            check("catalogue lists both system rows and source-specific required permissions \(source)", window.catalog.rows.map(\.permission) == [.accessibility, .screenRecording] && ServiceSystemPermissions.requiredPermissions(for: source) == (source == .timeline ? [.accessibility] : [.accessibility, .screenRecording]))
            check("native presenter construction does not show or activate window \(source)", !host.isVisible)
            host.close()
            check("owned permission window closes without showing \(source)", !host.isVisible)
            presenter = nil
            check("native presenter has no callback retention cycle \(source)", weakPresenter == nil)
        }
        check("all owned native permission windows delivered close cleanup", ownedCloses == 3)
        check("native window checks preserve foreground application", NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases, "owned_permission_windows_executed": true,
            "physical_input_screen_capture_focus_AX_action_or_preferences": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native permission presenter windows: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0 : 3
    }
}
