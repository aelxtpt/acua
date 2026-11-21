import Foundation

struct ControllerIPCScreenshot: Codable, Equatable, Sendable {
    let url: URL
    let mimeType: String
}
struct ControllerIPCAppSnapshot: Codable, Equatable, Sendable {
    let text: String
    let screenshot: ControllerIPCScreenshot?
}
struct ControllerIPCAppSnapshotResult: Codable, Equatable, Sendable {
    let app: IPCApp
    let appSnapshot: ControllerIPCAppSnapshot
    let appSpecificInstructions: String?
}

@MainActor enum ControllerNativeAppSnapshotReply {
    static func make(app: IPCApp, capture: ControllerNativeAppController.AppSnapshot,
                     instructions: String?) throws -> ControllerIPCAppSnapshotResult {
        let screenshot: ControllerIPCScreenshot?
        if let file = capture.attachment.screenshot {
            guard let mimeType = capture.attachment.mimeType else { throw ControllerAppSnapshotRequestFailure.missingScreenshotMIMEType }
            screenshot = .init(url: file.url, mimeType: mimeType)
        } else { screenshot = nil }
        return .init(app: app, appSnapshot: .init(text: capture.attachment.text, screenshot: screenshot),
                     appSpecificInstructions: instructions)
    }
}
