import Foundation
import CoreGraphics

enum DirectRequestType: String {
    case listApps = "ComputerUseIPCListAppsRequest"
    case appPolicy = "ComputerUseIPCAppPolicyRequest"
    case appStart = "ComputerUseIPCAppStartRequest"
    case appStop = "ComputerUseIPCAppStopRequest"
    case appModify = "ComputerUseIPCAppModifyRequest"
    case frontmostWindow = "ComputerUseIPCFrontmostWindowRequest"
    case appGetAppSnapshot = "ComputerUseIPCAppGetAppSnapshotRequest"
    case appStartCapture = "ComputerUseIPCAppStartCaptureRequest"
    case appNextCaptureUpdate = "ComputerUseIPCAppNextCaptureUpdateRequest"
    case appPerformAction = "ComputerUseIPCAppPerformActionRequest"
    case startAudioRecording = "ComputerUseIPCStartAudioRecordingRequest"
    case stopAudioRecording = "ComputerUseIPCStopAudioRecordingRequest"
    case agentTurnEnded = "ComputerUseIPCTurnEndedRequest"
    case statusItemMenuState = "ComputerUseIPCStatusItemMenuStateRequest"
    case eventStreamStart = "ComputerUseIPCEventStreamStartRequest"
    case eventStreamStatus = "ComputerUseIPCEventStreamStatusRequest"
    case eventStreamStop = "ComputerUseIPCEventStreamStopRequest"
}


// These app usage request types are decoded before the server prepares the
// authenticated request. Decode only their wire shapes here, before dispatch.
enum XPCAppUsageBody {
    private struct AppIdentifier: Codable { let app: String }
    private struct Modify: Codable {
        let app: String
        let modification: Modification
    }
    private enum Modification: Codable {
        case activate, deactivate

        var key: String {
            switch self {
            case .activate: "activate"
            case .deactivate: "deactivate"
            }
        }
    }
    private struct AppSnapshot: Codable {
        let app: String
        let disableDiff: Bool
        enum CodingKeys: String, CodingKey { case app, disableDiff }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            app = try fields.decode(String.self, forKey: .app)
            disableDiff = try fields.decodeIfPresent(Bool.self, forKey: .disableDiff) ?? false
        }
    }
    private struct PerformAction: Codable {
        let app: String
        let action: Action
    }

    private enum Target: Codable {
        case coordinate(CGPoint)
        case elementID(String)
    }

    private enum ComputerUseIPCScrollDirection: String, Codable { case up, down, left, right }
    private enum ComputerUseIPCPasteFormat: String, Codable { case text, md, html }
    private enum ComputerUseIPCTextSelection: String, Codable {
        case text
        case cursorBefore = "cursor_before"
        case cursorAfter = "cursor_after"
    }

    private enum Action: Codable {
        case click(at: Target, mouseButton: UInt32, clickCount: Int, duration: Double?, key: String?)
        case performSecondaryAction(elementID: String, action: String)
        case setValue(elementID: String, value: String)
        case selectText(elementID: String, text: String, prefix: String?, suffix: String?, selection: ComputerUseIPCTextSelection)
        case scroll(at: Target, direction: ComputerUseIPCScrollDirection, pages: Double)
        case drag(from: CGPoint, to: CGPoint)
        case pressKey(String, duration: Double?)
        case type(String)
        case paste(text: String, format: ComputerUseIPCPasteFormat)
    }

    private struct SocketEnvelope<Body: Codable>: Decodable {
        var params: SocketParameters<Body>?
    }
    private struct SocketParameters<Body: Codable>: Decodable {
        var clientApiVersion: String?
        var requestType: String
        var request: Body
        var agentTurnMetadata: ComputerUseJSONRPCCodexTurnMetadata?
        var deadlineUnixMilliseconds: Int?
    }
    private struct SocketMetadataEnvelope: Decodable { var params: SocketMetadataParameters }
    private struct SocketMetadataParameters: Decodable { var agentTurnMetadata: ComputerUseJSONRPCCodexTurnMetadata? }

    static func socketMetadata(_ data: Data) throws -> Data? {
        let metadata = try JSONDecoder().decode(SocketMetadataEnvelope.self, from: data).params.agentTurnMetadata
        return try metadata.map { try JSONEncoder().encode($0) }
    }
    static func bridge<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    static func socketBody<T: Codable>(_ type: T.Type, data: Data) throws -> Any {
        let envelope = try JSONDecoder().decode(SocketEnvelope<T>.self, from: data)
        guard let params = envelope.params else {
            throw SocketJSONRPC.Failure(code: -32602, message: "Invalid params")
        }
        return try bridge(params.request)
    }
    static func decodeSocket(_ data: Data, for type: DirectRequestType?) throws -> Any? {
        let result: Any
        switch type {
        case .appStart, .appStop, .appPolicy: result = try socketBody(AppIdentifier.self, data: data)
        case .appModify: result = try socketBody(Modify.self, data: data)
        case .appGetAppSnapshot: result = try socketBody(AppSnapshot.self, data: data)
        case .appPerformAction: result = try socketBody(PerformAction.self, data: data)
        default: return nil
        }
        return result
    }
    static func decode(_ data: Data?, for type: DirectRequestType?) throws -> Any {
        let body = data ?? Data()
        let decoder = JSONDecoder()
        switch type {
        case .appStart, .appStop, .appPolicy: return try bridge(decoder.decode(AppIdentifier.self, from: body))
        case .appModify: return try bridge(decoder.decode(Modify.self, from: body))
        case .appGetAppSnapshot: return try bridge(decoder.decode(AppSnapshot.self, from: body))
        case .appPerformAction: return try bridge(decoder.decode(PerformAction.self, from: body))
        default: return try decodeJSONDocument(body)
        }
    }
}
