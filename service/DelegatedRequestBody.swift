import Foundation

struct AgentTurnEndedRequest: Codable {
    let threadID: String
    let turnID: String?
}

// All remaining registered routes use the same typed request boundary as app
// actions. Decode before module owners, permission prompts or recording sinks.
enum DelegatedRequestBody {
    private struct Empty: Codable {}

    static func decode(_ data: Data?, requestType: String, socket: Bool) throws -> Any? {
        let data = data ?? Data()
        func body<T: Codable>(_ type: T.Type) throws -> Any {
            if socket { return try XPCAppUsageBody.socketBody(type, data: data) }
            return try XPCAppUsageBody.bridge(JSONDecoder().decode(type, from: data))
        }
        switch requestType {
        case "ComputerUseIPCListAppsRequest", "ComputerUseIPCFrontmostWindowRequest",
             "ComputerUseIPCStopAudioRecordingRequest", "ComputerUseIPCStatusItemMenuStateRequest":
            return try body(Empty.self)
        case "ComputerUseIPCStartAudioRecordingRequest": return try body(ComputerUseAudioStartRequest.self)
        case "ComputerUseIPCTurnEndedRequest": return try body(AgentTurnEndedRequest.self)
        case "ComputerUseIPCAppStartCaptureRequest": return try body(AppCaptureWire.Start.self)
        case "ComputerUseIPCAppNextCaptureUpdateRequest": return try body(AppCaptureWire.Next.self)
        case "ComputerUseIPCEventStreamStartRequest": return try body(EventStreamStartRequest.self)
        case "ComputerUseIPCEventStreamStatusRequest": return try body(EventStreamStatusRequest.self)
        case "ComputerUseIPCEventStreamStopRequest": return try body(EventStreamStopRequest.self)
        case "ComputerUseIPCCalendarListCalendarsRequest": return try body(CalendarIPCListCalendarsRequest.self)
        case "ComputerUseIPCCalendarListEventsRequest": return try body(CalendarIPCListEventsRequest.self)
        case "ComputerUseIPCCalendarGetEventRequest": return try body(CalendarIPCGetEventRequest.self)
        case "ComputerUseIPCCalendarCreateEventRequest": return try body(CalendarIPCCreateEventRequest.self)
        case "ComputerUseIPCCalendarUpdateEventRequest": return try body(CalendarIPCUpdateEventRequest.self)
        case "ComputerUseIPCCalendarDeleteEventRequest": return try body(CalendarIPCDeleteEventRequest.self)
        case "ComputerUseIPCMessagesFindChatsRequest": return try body(MessagesIPCFindChatsRequest.self)
        case "ComputerUseIPCMessagesSearchChatsRequest": return try body(MessagesIPCSearchChatsRequest.self)
        case "ComputerUseIPCMessagesReadMessagesRequest": return try body(MessagesIPCReadMessagesRequest.self)
        case "ComputerUseIPCMessagesSearchMessagesRequest": return try body(MessagesIPCSearchMessagesRequest.self)
        case "ComputerUseIPCMessagesReadImageRequest": return try body(MessagesIPCReadImageRequest.self)
        case "ComputerUseIPCMessagesCountActivityRequest": return try body(MessagesIPCCountActivityRequest.self)
        case "ComputerUseIPCMessagesPrepareSendRequest": return try body(MessagesIPCPrepareSendRequest.self)
        case "ComputerUseIPCMessagesCommitSendRequest": return try body(MessagesIPCCommitSendRequest.self)
        case "ComputerUseIPCTimelineStartRequest": return try body(TimelineStartRequest.self)
        case "ComputerUseIPCTimelineStatusRequest": return try body(TimelineStatusRequest.self)
        case "ComputerUseIPCTimelineStopRequest": return try body(TimelineStopRequest.self)
        case "ComputerUseIPCTimelinePauseRequest": return try body(TimelinePauseRequest.self)
        case "ComputerUseIPCTimelineResumeRequest": return try body(TimelineResumeRequest.self)
        case "ComputerUseIPCTimelineGetSettingsRequest": return try body(TimelineGetSettingsRequest.self)
        case "ComputerUseIPCTimelineUpdateSettingsRequest": return try body(TimelineUpdateSettingsRequest.self)
        case "ComputerUseIPCTimelineUpdateObservationPolicyRequest": return try body(TimelineUpdateObservationPolicyRequest.self)
        case "ComputerUseIPCTimelineClearHistoryRequest": return try body(TimelineClearHistoryRequest.self)
        default: return nil
        }
    }
}
