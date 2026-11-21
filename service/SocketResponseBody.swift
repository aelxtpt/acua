import Foundation

struct SocketResponseSerializationFailure: Error {
    let operation: String
    let underlying: Error
}

/// The socket decodes the native reply as the request's associated
/// Response, then encodes that value into JSON-RPC. Invalid replies close the
/// connection; unknown Codable fields do not become socket extensions.
enum SocketResponseBody {
    private struct Empty: Codable {}
    private struct DiscoveredApp: Codable {
        let displayName: String
        let bundleIdentifier: String
        let appPath: String?
        let lastUsedDate: Date?
        let useCount: Int?
        let isRunning: Bool
        let isFrontmost: Bool
    }
    private struct FrontmostWindow: Codable {
        let bundleIdentifier: String
        let name: String
        let windowTitle: String?
    }
    private struct AppSnapshot: Codable {
        let text: String
        let screenshot: AppCaptureWire.Screenshot?
    }
    private struct AppSnapshotResult: Codable {
        let app: IPCApp
        let appSnapshot: AppSnapshot
        let appSpecificInstructions: String?
    }
    private struct ActionResult: Codable {
        let app: IPCApp
        let appSnapshot: AppSnapshot?
    }
    private struct Audio: Codable { let url: URL }

    static func normalize(_ result: Any?, for requestType: String) throws -> Any {
        // A backend encoding failure is still an operation error. Only failures
        // in the socket's reply conversion are terminal serialization failures.
        let data = try JSONSerialization.data(withJSONObject: result ?? NSNull(), options: [.fragmentsAllowed])
        return try normalizeData(data, for: requestType)
    }

    static func normalizeData(_ data: Data, for requestType: String) throws -> Any {
        func reply<T: Codable>(_ type: T.Type) throws -> Any {
            let value: T
            do { value = try JSONDecoder().decode(type, from: data) }
            catch { throw SocketResponseSerializationFailure(operation: "decodeResponse", underlying: error) }
            let encoded: Data
            do { encoded = try JSONEncoder().encode(value) }
            catch { throw SocketResponseSerializationFailure(operation: "encodeResponse", underlying: error) }
            return try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        }
        switch requestType {
        case "ComputerUseIPCListAppsRequest": return try reply([DiscoveredApp].self)
        case "ComputerUseIPCFrontmostWindowRequest": return try reply(FrontmostWindow?.self)
        case "ComputerUseIPCAppStartRequest", "ComputerUseIPCAppStopRequest", "ComputerUseIPCAppModifyRequest":
            return try reply(IPCAppState.self)
        case "ComputerUseIPCAppGetAppSnapshotRequest": return try reply(AppSnapshotResult.self)
        case "ComputerUseIPCAppPerformActionRequest": return try reply(ActionResult.self)
        case "ComputerUseIPCStartAudioRecordingRequest", "ComputerUseIPCTurnEndedRequest",
             "ComputerUseIPCCalendarDeleteEventRequest": return try reply(Empty.self)
        case "ComputerUseIPCStopAudioRecordingRequest": return try reply(Audio.self)
        case "ComputerUseIPCAppStartCaptureRequest": return try reply(AppCaptureWire.StartResponse.self)
        case "ComputerUseIPCAppNextCaptureUpdateRequest": return try reply(AppCaptureWire.Update.self)
        case "ComputerUseIPCEventStreamStartRequest", "ComputerUseIPCEventStreamStatusRequest", "ComputerUseIPCEventStreamStopRequest":
            return try reply(EventStreamSessionStatus.self)
        case "ComputerUseIPCStatusItemMenuStateRequest": return try reply(StatusMenuState.self)
        case "ComputerUseIPCTimelineStartRequest", "ComputerUseIPCTimelineStopRequest", "ComputerUseIPCTimelineStatusRequest",
             "ComputerUseIPCTimelinePauseRequest", "ComputerUseIPCTimelineResumeRequest", "ComputerUseIPCTimelineClearHistoryRequest":
            return try reply(TimelineStatus.self)
        case "ComputerUseIPCTimelineGetSettingsRequest", "ComputerUseIPCTimelineUpdateSettingsRequest",
             "ComputerUseIPCTimelineUpdateObservationPolicyRequest": return try reply(TimelineSettings.self)
        case "ComputerUseIPCCalendarListCalendarsRequest": return try reply([CalendarIPCCalendar].self)
        case "ComputerUseIPCCalendarListEventsRequest": return try reply(CalendarIPCEventsPage.self)
        case "ComputerUseIPCCalendarGetEventRequest", "ComputerUseIPCCalendarCreateEventRequest", "ComputerUseIPCCalendarUpdateEventRequest":
            return try reply(CalendarIPCEvent.self)
        case "ComputerUseIPCMessagesFindChatsRequest": return try reply(MessagesIPCChatsPage.self)
        case "ComputerUseIPCMessagesSearchChatsRequest": return try reply(MessagesIPCChatSearchPage.self)
        case "ComputerUseIPCMessagesReadMessagesRequest", "ComputerUseIPCMessagesSearchMessagesRequest":
            return try reply(MessagesIPCMessagesPage.self)
        case "ComputerUseIPCMessagesPrepareSendRequest": return try reply(MessagesIPCPreparedSend.self)
        case "ComputerUseIPCMessagesCommitSendRequest": return try reply(MessagesIPCSendResult.self)
        case "ComputerUseIPCMessagesCountActivityRequest": return try reply(MessagesIPCActivityResult.self)
        case "ComputerUseIPCMessagesReadImageRequest": return try reply(MessagesIPCImage.self)
        default:
            // AppPolicy has a separate socket handler and provider.
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
    }
}
