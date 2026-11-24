import Foundation
import MCP

// Unit tests for what get_app_state returns to an MCP client: the screenshot
// as base64 image content with its MIME type, and app-specific instructions
// once per app for the life of the MCP connection. File reads are injected;
// no service is involved.

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

        print("\(passed) MCP output tests passed")
    }
}
