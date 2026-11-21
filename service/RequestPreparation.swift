import Foundation

/// Per-request preparation (unlock and activity holding) by request type.
/// AppPolicy takes a separate path; an exemption only skips unlock/activity work.
struct RequestPreparation {
    let requestType: String

    private static let appUsage: Set<String> = [
        "ComputerUseIPCAppStartRequest", "ComputerUseIPCAppGetAppSnapshotRequest",
        "ComputerUseIPCAppPerformActionRequest",
    ]
    private static let exempt: Set<String> = [
        "ComputerUseIPCTurnEndedRequest",
        "ComputerUseIPCTimelineStartRequest", "ComputerUseIPCTimelineStatusRequest",
        "ComputerUseIPCTimelineStopRequest", "ComputerUseIPCTimelinePauseRequest",
        "ComputerUseIPCTimelineResumeRequest", "ComputerUseIPCTimelineGetSettingsRequest",
        "ComputerUseIPCTimelineUpdateSettingsRequest", "ComputerUseIPCTimelineUpdateObservationPolicyRequest",
        "ComputerUseIPCTimelineClearHistoryRequest",
        "ComputerUseIPCCalendarListCalendarsRequest", "ComputerUseIPCCalendarListEventsRequest",
        "ComputerUseIPCCalendarGetEventRequest", "ComputerUseIPCCalendarCreateEventRequest",
        "ComputerUseIPCCalendarUpdateEventRequest", "ComputerUseIPCCalendarDeleteEventRequest",
        "ComputerUseIPCMessagesFindChatsRequest", "ComputerUseIPCMessagesSearchChatsRequest",
        "ComputerUseIPCMessagesReadMessagesRequest", "ComputerUseIPCMessagesSearchMessagesRequest",
        "ComputerUseIPCMessagesPrepareSendRequest", "ComputerUseIPCMessagesCommitSendRequest",
        "ComputerUseIPCMessagesCountActivityRequest", "ComputerUseIPCMessagesReadImageRequest",
    ]

    var isAppUsage: Bool { Self.appUsage.contains(requestType) }
    var isPolicy: Bool { requestType == "ComputerUseIPCAppPolicyRequest" }
    var decodesBeforePreparation: Bool { isAppUsage || isPolicy }
    var preparesAgentTurn: Bool {
        isAppUsage || ["ComputerUseIPCListAppsRequest", "ComputerUseIPCStartAudioRecordingRequest",
                       "ComputerUseIPCStopAudioRecordingRequest"].contains(requestType)
    }
    var holdsActivity: Bool { !isPolicy && !Self.exempt.contains(requestType) }
}
