import Foundation

struct ComputerUseIPCAppStartCaptureAnimationRect: Codable, Equatable, Sendable {
    let x, y, width, height: Double
}
struct ComputerUseIPCAppStartCaptureAnimationColor: Codable, Equatable, Sendable {
    let red, green, blue: Int
}
struct ComputerUseIPCAppStartCaptureAnimationDisplay: Codable, Equatable, Sendable {
    let id: Int
    let bounds, workArea: ComputerUseIPCAppStartCaptureAnimationRect
    let scaleFactor: Double
}
enum ComputerUseIPCAppStartCaptureAnimationPresentationStyle: String, Codable, Sendable {
    case standard, quickChat = "quick_chat"
}
struct ComputerUseIPCAppStartCaptureAnimationTarget: Codable, Equatable, Sendable {
    let destinationFrame: ComputerUseIPCAppStartCaptureAnimationRect
    let destinationCornerRadius: Double?
    let destinationBackgroundColor, destinationPrimaryTextColor: ComputerUseIPCAppStartCaptureAnimationColor?
    let presentationStyle: ComputerUseIPCAppStartCaptureAnimationPresentationStyle
    let agentDisplay: ComputerUseIPCAppStartCaptureAnimationDisplay
    enum CodingKeys: String, CodingKey {
        case destinationFrame, destinationCornerRadius, destinationBackgroundColor, destinationPrimaryTextColor
        case presentationStyle, agentDisplay
    }
}
extension ComputerUseIPCAppStartCaptureAnimationTarget {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinationFrame = try c.decode(ComputerUseIPCAppStartCaptureAnimationRect.self, forKey: .destinationFrame)
        destinationCornerRadius = try? c.decode(Double.self, forKey: .destinationCornerRadius)
        destinationBackgroundColor = try? c.decode(ComputerUseIPCAppStartCaptureAnimationColor.self, forKey: .destinationBackgroundColor)
        destinationPrimaryTextColor = try? c.decode(ComputerUseIPCAppStartCaptureAnimationColor.self, forKey: .destinationPrimaryTextColor)
        presentationStyle = (try? c.decode(ComputerUseIPCAppStartCaptureAnimationPresentationStyle.self, forKey: .presentationStyle)) ?? .standard
        agentDisplay = try c.decode(ComputerUseIPCAppStartCaptureAnimationDisplay.self, forKey: .agentDisplay)
    }
}

struct ComputerUseIPCAppStartCaptureRequest: ComputerUseIPCRequest, Codable, Sendable {
    typealias Response = ComputerUseIPCAppStartCaptureResponse
    let app, requestID, permissionRequestID: String
    let animationTarget: ComputerUseIPCAppStartCaptureAnimationTarget?
    let version: Version
    enum CodingKeys: String, CodingKey {
        case app, animationTarget, version
        case requestID = "requestId", permissionRequestID = "permissionRequestId"
    }
    enum Version: Codable, Equatable, Sendable {
        case future(Int), initial, reliableFinalFrame
        init(rawValue: Int) {
            switch rawValue { case 1: self = .initial; case 2: self = .reliableFinalFrame; default: self = .future(rawValue) }
        }
        var rawValue: Int {
            switch self { case .future(let value): return value; case .initial: return 1; case .reliableFinalFrame: return 2 }
        }
        var supportsReliableFinalFrame: Bool {
            switch self { case .initial: return false; case .reliableFinalFrame: return true; case .future(let value): return value > 1 }
        }
        init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(Int.self)) }
        func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
}
extension ComputerUseIPCAppStartCaptureRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        requestID = try c.decode(String.self, forKey: .requestID)
        permissionRequestID = try c.decodeIfPresent(String.self, forKey: .permissionRequestID) ?? requestID
        animationTarget = try? c.decode(ComputerUseIPCAppStartCaptureAnimationTarget.self, forKey: .animationTarget)
        version = try c.decodeIfPresent(Version.self, forKey: .version) ?? .initial
    }
}
enum ComputerUseIPCAppStartCapturePermissionGrantState: String, Codable, Sendable {
    case noneGranted = "none_granted", accessibilityGranted = "accessibility_granted"
    case screenRecordingGranted = "screen_recording_granted", bothGranted = "both_granted"
}
struct ComputerUseIPCAppStartCaptureResponse: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable { case started, appshotPermissionsAbandoned = "appshot_permissions_abandoned" }
    let result: Result
    let animationDuration, transitionSnapshotHeight, transitionSpringResponse, transitionSpringDampingFraction: Double?
    let permissionGrantState: ComputerUseIPCAppStartCapturePermissionGrantState?
}
