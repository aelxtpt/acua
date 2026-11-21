import Foundation

/// Wire names and decoder defaults of the capture protocol.
/// A capture produces a finite sequence of stages, rather than a polling stream.
enum AppCaptureWire {
    struct Version: Codable, Equatable {
        let rawValue: Int
        static let initial = Version(rawValue: 1)
        static let reliableFinalFrame = Version(rawValue: 2)
        var supportsReliableFinalFrame: Bool { rawValue > 1 }
        init(rawValue: Int) { self.rawValue = rawValue }
        init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(Int.self) }
        func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
    struct Rect: Codable, Equatable { let x, y, width, height: Double }
    struct Color: Codable, Equatable { let red, green, blue: Int }
    struct Display: Codable, Equatable {
        let id: Int
        let bounds, workArea: Rect
        let scaleFactor: Double
    }
    enum PresentationStyle: String, Codable { case standard, quickChat = "quick_chat" }
    struct AnimationTarget: Codable, Equatable {
        let destinationFrame: Rect
        let destinationCornerRadius: Double?
        let destinationBackgroundColor, destinationPrimaryTextColor: Color?
        let presentationStyle: PresentationStyle
        let agentDisplay: Display
        enum CodingKeys: String, CodingKey {
            case destinationFrame, destinationCornerRadius, destinationBackgroundColor
            case destinationPrimaryTextColor, presentationStyle, agentDisplay
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            destinationFrame = try c.decode(Rect.self, forKey: .destinationFrame)
            // Each optional styling field fails independently.
            destinationCornerRadius = try? c.decode(Double.self, forKey: .destinationCornerRadius)
            destinationBackgroundColor = try? c.decode(Color.self, forKey: .destinationBackgroundColor)
            destinationPrimaryTextColor = try? c.decode(Color.self, forKey: .destinationPrimaryTextColor)
            presentationStyle = (try? c.decode(PresentationStyle.self, forKey: .presentationStyle)) ?? .standard
            agentDisplay = try c.decode(Display.self, forKey: .agentDisplay)
        }
    }
    struct Start: Codable, Equatable {
        let app, requestID, permissionRequestID: String
        let animationTarget: AnimationTarget?
        let version: Version
        enum CodingKeys: String, CodingKey {
            case app, animationTarget, version
            case requestID = "requestId"
            case permissionRequestID = "permissionRequestId"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = try c.decode(String.self, forKey: .app)
            requestID = try c.decode(String.self, forKey: .requestID)
            let permissionID = try c.decodeIfPresent(String.self, forKey: .permissionRequestID)
            permissionRequestID = permissionID ?? requestID
            // An undecodable animation target is ignored rather than rejected.
            animationTarget = try? c.decode(AnimationTarget.self, forKey: .animationTarget)
            version = try c.decodeIfPresent(Version.self, forKey: .version) ?? .initial
        }
    }
    struct Next: Codable, Equatable {
        let requestID: String
        enum CodingKeys: String, CodingKey { case requestID = "requestId" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try c.decode(String.self, forKey: .requestID)
        }
    }
    enum StartResult: String, Codable { case started, permissionsAbandoned = "appshot_permissions_abandoned" }
    enum PermissionState: String, Codable {
        case none = "none_granted", accessibility = "accessibility_granted"
        case screenRecording = "screen_recording_granted", both = "both_granted"
    }
    struct StartResponse: Codable, Equatable {
        let result: StartResult
        var animationDuration: Double? = nil
        var transitionSnapshotHeight: Double? = nil
        var transitionSpringResponse: Double? = nil
        var transitionSpringDampingFraction: Double? = nil
        var permissionGrantState: PermissionState? = nil
    }
    enum UpdateType: String, Codable { case axText, completed, failed, metadata, screenshot }
    enum FailureReason: String, Codable {
        case blockedByPolicy = "blocked_by_policy"
        case screenshotCaptureFailed = "screenshot_capture_failed"
        case unknownCaptureFailed = "unknown_capture_failed"
    }
    struct Screenshot: Codable, Equatable { let url: URL; let mimeType: String }
    struct Update: Codable, Equatable {
        let type: UpdateType
        let app: IPCApp
        var text: String? = nil
        var screenshot: Screenshot? = nil
        var transitionSnapshotURL: URL? = nil
        var failureReason: FailureReason? = nil
    }
}
