import Foundation
import MCP

// Unit tests for what get_app_state returns to an MCP client: the screenshot
// as base64 image content with its MIME type, and app-specific instructions
// once per app for the life of the MCP connection; the warning added when a
// window's accessibility tree has no content; and the one added when an action
// returns the same tree as before it. File reads are injected; no
// service is involved.

@main
enum AcuaMCPOutputTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static let screenshotURL = URL(fileURLWithPath: "/tmp/acua-output-test.jpg")
    private static let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    private static func result(bundle: String, instructions: String?, screenshot: Bool = true) -> ComputerUseIPCAppSnapshotResult {
        ComputerUseIPCAppSnapshotResult(app: .init(pid: 42, bundleIdentifier: bundle, appPath: nil),
            appSnapshot: .init(text: "tree", screenshot: screenshot ? .init(url: screenshotURL, mimeType: "image/jpeg") : nil),
            appSpecificInstructions: instructions)
    }

    private static func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            guard case .text(let text) = content else { return nil }
            return text
        }.joined()
    }

    private static func images(_ result: CallTool.Result) -> [(data: String, mimeType: String)] {
        result.content.compactMap { content in
            guard case .image(let data, let mimeType, _) = content else { return nil }
            return (data, mimeType)
        }
    }

    static func main() async {
        let read: @Sendable (URL) throws -> Data = { url in
            guard url == screenshotURL else { throw CocoaError(.fileNoSuchFile) }
            return imageBytes
        }

        let state = await AutomationMCPFormatting.state(result(bundle: "com.apple.Safari", instructions: "Use the address bar."),
                                                        deliveryState: .init(), read: read)
        let image = images(state).first
        check("State_WithScreenshot_SendsFileBytesAsBase64Image",
              image?.data == imageBytes.base64EncodedString() && image?.mimeType == "image/jpeg", "\(images(state))")
        check("State_WithScreenshot_TextComesBeforeImage", {
            guard case .text = state.content.first, case .image = state.content.last else { return false }
            return state.content.count == 2
        }())

        let unreadable = await AutomationMCPFormatting.state(result(bundle: "com.apple.Safari", instructions: nil),
            deliveryState: .init(), read: { _ in throw CocoaError(.fileNoSuchFile) })
        check("State_UnreadableScreenshot_TextOnly", images(unreadable).isEmpty && text(unreadable).contains("tree"))

        let noScreenshot = await AutomationMCPFormatting.state(result(bundle: "com.apple.Safari", instructions: nil, screenshot: false),
                                                               deliveryState: .init(), read: read)
        check("State_NoScreenshot_TextOnly", images(noScreenshot).isEmpty)

        // One delivery state per MCP connection, as the server creates it.
        let connection = AppInstructionDeliveryState()
        let first = await AutomationMCPFormatting.state(result(bundle: "com.apple.Safari", instructions: "Use the address bar."),
                                                        deliveryState: connection, read: read)
        let second = await AutomationMCPFormatting.state(result(bundle: "com.apple.Safari", instructions: "Use the address bar."),
                                                         deliveryState: connection, read: read)
        let otherApp = await AutomationMCPFormatting.state(result(bundle: "com.google.Chrome", instructions: "Use the omnibox."),
                                                           deliveryState: connection, read: read)
        check("State_FirstCallForApp_IncludesInstructions",
              text(first).contains("<app_specific_instructions>\nUse the address bar.\n</app_specific_instructions>"))
        check("State_SecondCallForSameApp_OmitsInstructions", !text(second).contains("app_specific_instructions"), text(second))
        check("State_OtherAppOnSameConnection_IncludesItsInstructions", text(otherApp).contains("Use the omnibox."))

        let newConnection = await AutomationMCPFormatting.state(result(bundle: "com.apple.Safari", instructions: "Use the address bar."),
                                                                deliveryState: .init(), read: read)
        check("State_NewConnection_IncludesInstructionsAgain", text(newConnection).contains("Use the address bar."))

        // An app first seen without instructions is still marked delivered,
        // because the app is recorded before its result is formatted.
        let quiet = AppInstructionDeliveryState()
        _ = await AutomationMCPFormatting.state(result(bundle: "com.apple.TextEdit", instructions: nil), deliveryState: quiet, read: read)
        let later = await AutomationMCPFormatting.state(result(bundle: "com.apple.TextEdit", instructions: "Late."),
                                                        deliveryState: quiet, read: read)
        check("State_AppFirstSeenWithoutInstructions_LaterInstructionsOmitted", !text(later).contains("Late."))

        // What a GPUI app returned while it was not drawing frames: the
        // window and its standard buttons, and nothing the app shows.
        let emptyTree = [
            "0 standard window Example, Secondary Actions: Raise",
            "\t1 close button",
            "\t2 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window",
            "\t3 minimize button",
            "4 menu bar",
            "\t5 Example",
        ].joined(separator: "\n")
        let fullTree = [
            "0 standard window Example, Secondary Actions: Raise",
            "\t1 container",
            "\t\t2 button Refresh",
            "\t\t3 button Board",
            "\t4 close button",
            "\t5 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window",
            "\t6 minimize button",
            "7 menu bar",
            "\t8 Example",
        ].joined(separator: "\n")
        func snapshot(_ tree: String) -> ComputerUseIPCAppSnapshotResult {
            ComputerUseIPCAppSnapshotResult(app: .init(pid: 42, bundleIdentifier: "com.example.gpui", appPath: nil),
                appSnapshot: .init(text: tree, screenshot: nil), appSpecificInstructions: nil)
        }
        func action(_ tree: String?) -> ComputerUseIPCActionResult {
            ComputerUseIPCActionResult(app: .init(pid: 42, bundleIdentifier: "com.example.gpui", appPath: nil),
                appSnapshot: tree.map { .init(text: $0, screenshot: nil) })
        }

        check("EmptyWindow_OnlyStandardButtons_IsDetected", AutomationMCPFormatting.windowHasNoContent(emptyTree))
        check("EmptyWindow_WindowWithoutChildren_IsDetected",
              AutomationMCPFormatting.windowHasNoContent("0 standard window Untitled\n1 menu bar\n\t2 File"))
        check("EmptyWindow_WindowWithContent_IsNotDetected", !AutomationMCPFormatting.windowHasNoContent(fullTree))
        check("EmptyWindow_MenuBarOnly_IsNotDetected", !AutomationMCPFormatting.windowHasNoContent("0 menu bar\n\t1 Finder"))
        check("EmptyWindow_TextWithoutElements_IsNotDetected", !AutomationMCPFormatting.windowHasNoContent("tree"))

        let emptyState = text(AutomationMCPFormatting.state(snapshot(emptyTree), includeInstructions: false))
        check("State_EmptyWindow_WarnsAfterTheTree",
              emptyState.contains("</app_state>\nWarning: this window's accessibility tree has no content elements"), emptyState)
        check("State_EmptyWindow_KeepsTheTree", emptyState.contains(emptyTree))
        let fullState = text(AutomationMCPFormatting.state(snapshot(fullTree), includeInstructions: false))
        check("State_WindowWithContent_HasNoWarning", !fullState.contains("Warning:"), fullState)

        // A click, drag or key press on such a window used to come back as a
        // plain success with the same empty tree.
        let emptyAction = text(AutomationMCPFormatting.action(action(emptyTree)))
        check("Action_EmptyWindow_SaysTheEffectCannotBeConfirmed",
              emptyAction.contains("Warning: the action was sent, but its effect cannot be confirmed"), emptyAction)
        check("Action_EmptyWindow_WarnsAgainstRepeating", emptyAction.contains("Do not repeat the action"), emptyAction)
        let fullAction = text(AutomationMCPFormatting.action(action(fullTree)))
        check("Action_WindowWithContent_IsUnchanged", fullAction == "App=com.example.gpui (pid 42)\n" + fullTree, fullAction)
        let noSnapshot = text(AutomationMCPFormatting.action(action(nil)))
        check("Action_WithoutSnapshot_IsUnchanged", !noSnapshot.contains("Warning:"), noSnapshot)

        // Seen live: a window hidden behind another app's window stopped
        // updating, and a click and three type_text calls each came back with
        // the tree from before them, with no warning.
        let unchangedText = text(AutomationMCPFormatting.action(action(fullTree), previousTree: fullTree))
        check("Action_SameTreeAsBefore_Warns",
              unchangedText.hasSuffix("\n" + AutomationMCPFormatting.unchangedAfterActionWarning), unchangedText)
        check("Action_SameTreeAsBefore_KeepsTheTree", unchangedText.contains(fullTree))
        check("Action_TreeChanged_IsUnchanged",
              text(AutomationMCPFormatting.action(action(fullTree), previousTree: emptyTree + "\n")) == "App=com.example.gpui (pid 42)\n" + fullTree)
        check("Action_NoChangeDifference_Warns",
              text(AutomationMCPFormatting.action(action("no_change"))).contains(AutomationMCPFormatting.unchangedAfterActionWarning))
        check("Action_NoEarlierTree_HasNoWarning", !text(AutomationMCPFormatting.action(action(fullTree))).contains("Warning:"))
        let emptyAndUnchanged = text(AutomationMCPFormatting.action(action(emptyTree), previousTree: emptyTree))
        check("Action_EmptyAndUnchanged_OnlyTheEmptyWindowWarning",
              emptyAndUnchanged.contains("effect cannot be confirmed") && !emptyAndUnchanged.contains("is the same as before"),
              emptyAndUnchanged)

        // One history per MCP connection, as the server creates it.
        let trees = AppTreeHistory()
        _ = await AutomationMCPFormatting.state(snapshot(fullTree), deliveryState: .init(), trees: trees, read: read)
        let afterState = text(await AutomationMCPFormatting.action(action(fullTree), trees: trees, read: read))
        check("History_ActionAfterStateWithSameTree_Warns", afterState.contains("is the same as before"), afterState)
        let changed = text(await AutomationMCPFormatting.action(action(emptyTree.replacingOccurrences(of: "Example", with: "Other")),
                                                                trees: trees, read: read))
        check("History_ActionWithNewTree_HasNoUnchangedWarning", !changed.contains("is the same as before"), changed)
        _ = await AutomationMCPFormatting.action(action(nil), trees: trees, read: read)
        let afterForget = text(await AutomationMCPFormatting.action(action(fullTree), trees: trees, read: read))
        check("History_ActionWithoutTree_ForgetsTheTree", !afterForget.contains("is the same as before"), afterForget)
        let otherAppAction = ComputerUseIPCActionResult(app: .init(pid: 43, bundleIdentifier: "com.example.other", appPath: nil),
            appSnapshot: .init(text: fullTree, screenshot: nil))
        check("History_OtherApp_HasItsOwnTree",
              !text(await AutomationMCPFormatting.action(otherAppAction, trees: trees, read: read)).contains("is the same as before"))

        print("\(passed) MCP output tests passed")
    }
}
