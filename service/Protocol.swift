import Foundation
import CoreFoundation

let kApiVersion = "AcuaComputerUseIPC-5"
let kMaxFrameBytes = 8_388_608

enum CUErrorCode: Int {
    case senderProcessNotAuthenticated = -10000
    case couldNotGetRequestData = -10001
    case couldNotGetRequestTypeName = -10002
    case couldNotResolveRequestType = -10003
    case unhandledEvent = -10004
    case unknownError = -10005
    case appNotAllowed = -10006
    case runningApplicationNotFound = -10007
    case accessibilityError = -10008
    case permissionsNotGranted = -10009
    case invalidApp = -10010
    case noActiveSession = -10011
    case userStoppedSession = -10012
    case incompatibleClientVersion = -10013
    case permissionsPending = -10014
    case blockedURL = -10015
    case userIntervened = -10016
    case couldNotGetSenderPID = -10017
    case ambiguousApp = -10018
    case couldNotGetBootstrapPort = -10019
    case screenLocked = -10020
    case agentTurnAlreadyEnded = -10021
    case messagesPermissionsPending = -10022
    case messagesPermissionsDenied = -10023
    case messagesQueryTimedOut = -10024
    case messagesInvalidRequest = -10025
    case messagesAmbiguousDestination = -10026
    case messagesSendPlanUnavailable = -10027
    case messagesSendOutcomeUncertain = -10028
    case messagesSendRateLimited = -10029
    case calendarPermissionsPending = -10030
    case calendarPermissionsDenied = -10031
    case calendarInvalidRequest = -10032
}

struct ServiceError: Error {
    let code: CUErrorCode
    let message: String
    init(_ code: CUErrorCode, _ message: String) { self.code = code; self.message = message }
}

// MARK: - Framing  (<uint32 LE byte length><JSON data>)

func encodeFrame(_ text: String) -> Data {
    let body = Data(text.utf8)
    var frame = Data()
    var length = UInt32(body.count).littleEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(body)
    return frame
}

struct FrameDecoder {
    private var buffer = Data()
    private(set) var failure: ServiceError?

    mutating func append(_ data: Data) -> [Data] {
        guard failure == nil else { return [] }
        buffer.append(data)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let size = Int(UInt32(littleEndian: length))
            guard size <= kMaxFrameBytes else {
                failure = ServiceError(.couldNotGetRequestData, "Frame exceeds maximum size")
                buffer.removeAll(keepingCapacity: false)
                return messages
            }
            guard buffer.count >= 4 + size else { break }
            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            let end = buffer.index(start, offsetBy: size)
            messages.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return messages
    }
}

// MARK: - JSON helpers

typealias JSON = [String: Any]

private struct JSONDocument: Decodable {}

func decodeJSONDocument(_ data: Data) throws -> Any {
    // Socket and XPC requests pass Data to Foundation's JSONDecoder.
    // Validate with that decoder before bridging to the dynamic dispatcher;
    // JSONSerialization alone accepts some encodings JSONDecoder rejects.
    _ = try JSONDecoder().decode(JSONDocument.self, from: data)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

func jsonFrameObject(_ data: Data) -> JSON? {
    (try? decodeJSONDocument(data)) as? JSON
}

func jsonObject(_ data: Data) -> JSON? {
    (try? JSONSerialization.jsonObject(with: data)) as? JSON
}
func jsonString(_ value: Any, pretty: Bool = false) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: pretty ? [.sortedKeys] : []),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
func asDict(_ value: Any?) -> JSON? { value as? JSON }
func str(_ value: Any?) -> String? { value as? String }
func intValue(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    let integer = n.intValue
    return n.compare(NSNumber(value: integer)) == .orderedSame ? integer : nil
}
func doubleValue(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}
func boolValue(_ value: Any?) -> Bool? {
    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}
func array(_ value: Any?) -> [Any]? { value as? [Any] }
