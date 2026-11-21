import Foundation
import CoreGraphics

struct ComputerUseIPCApp: Codable, Equatable, Sendable {
    let pid: Int32
    let bundleIdentifier: String
    let appPath: String?
}

struct ComputerUseIPCAppState: Codable, Equatable, Sendable {
    let active: Bool
    let currentApp: ComputerUseIPCApp?
}

enum ComputerUseIPCTarget: Codable, Equatable, Sendable {
    case coordinate(CGPoint), elementID(String)
}

enum ComputerUseIPCScrollDirection: String, Codable, Sendable { case up, down, left, right }
enum ComputerUseIPCPasteFormat: String, Codable, Sendable { case text, md, html }
enum ComputerUseIPCTextSelection: String, Codable, Sendable {
    case text, cursorBefore = "cursor_before", cursorAfter = "cursor_after"
}

enum ComputerUseIPCAction: Codable, Equatable, Sendable {
    case click(at: ComputerUseIPCTarget, mouseButton: UInt32, clickCount: Int, duration: Double?, key: String?)
    case performSecondaryAction(elementID: String, action: String)
    case setValue(elementID: String, value: String)
    case selectText(elementID: String, text: String, prefix: String?, suffix: String?, selection: ComputerUseIPCTextSelection)
    case scroll(at: ComputerUseIPCTarget, direction: ComputerUseIPCScrollDirection, pages: Double)
    case drag(from: CGPoint, to: CGPoint)
    case pressKey(String, duration: Double?)
    case type(String)
    case paste(text: String, format: ComputerUseIPCPasteFormat)
}

struct ComputerUseIPCScreenshot: Codable, Equatable, Sendable {
    let url: URL
    let mimeType: String
}

struct ComputerUseIPCAppSnapshot: Codable, Equatable, Sendable {
    let text: String
    let screenshot: ComputerUseIPCScreenshot?
}

struct ComputerUseIPCAppSnapshotResult: Codable, Equatable, Sendable {
    let app: ComputerUseIPCApp
    let appSnapshot: ComputerUseIPCAppSnapshot
    let appSpecificInstructions: String?
}

struct ComputerUseIPCActionResult: Codable, Equatable, Sendable {
    let app: ComputerUseIPCApp
    let appSnapshot: ComputerUseIPCAppSnapshot?
}

struct ComputerUseIPCAppStartRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppState
    let app: String
}

struct ComputerUseIPCAppStopRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppState
    let app: String
}

struct ComputerUseIPCAppModifyRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppState
    enum Modification: Codable, Sendable { case activate, deactivate }
    let app: String
    let modification: Modification
}

struct ComputerUseIPCAppGetAppSnapshotRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppSnapshotResult
    let app: String
    let disableDiff: Bool

    init(app: String, disableDiff: Bool = false) {
        self.app = app
        self.disableDiff = disableDiff
    }

    enum CodingKeys: String, CodingKey { case app, disableDiff }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        app = try fields.decode(String.self, forKey: .app)
        disableDiff = try fields.decodeIfPresent(Bool.self, forKey: .disableDiff) ?? false
    }
}

struct ComputerUseIPCAppPerformActionRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCActionResult
    let app: String
    let action: ComputerUseIPCAction
}
