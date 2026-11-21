import Foundation

enum ComputerUseIPCTimelineObservationDefaultBehavior: String, Codable, Sendable {
    case observe, doNotObserve = "do_not_observe"
}
enum ComputerUseIPCTimelineObservationRuleScope: String, Codable, Sendable { case app, url }
struct ComputerUseIPCTimelineObservationRule: Codable, Equatable, Sendable {
    let scope: ComputerUseIPCTimelineObservationRuleScope
    let bundleID: String?
    let urlDomain: String?
}
struct ComputerUseIPCTimelineObservationSettings: Codable, Equatable, Sendable {
    let defaultApplicationBehavior: ComputerUseIPCTimelineObservationDefaultBehavior
    let defaultURLBehavior: ComputerUseIPCTimelineObservationDefaultBehavior
    let allowlist: [ComputerUseIPCTimelineObservationRule]
    let blocklist: [ComputerUseIPCTimelineObservationRule]
}
struct ComputerUseIPCTimelineSettings: Codable, Equatable, Sendable {
    let observation: ComputerUseIPCTimelineObservationSettings
}
enum ComputerUseIPCTimelineState: String, Codable, Sendable { case stopped, running, paused }
struct ComputerUseIPCTimelineStatus: Codable, Equatable, Sendable {
    let state: ComputerUseIPCTimelineState
    let eventStreamRootPath: String?
    let currentSegmentEventsPath: String?
    let currentSegmentMetadataPath: String?
    let suppressedEventsPath: String?
    let startedAt: Date?
    let endedAt: Date?
}
struct ComputerUseIPCTimelinePauseRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCTimelineStatus
    enum Duration: String, Codable, Sendable {
        case thirtyMinutes = "thirty_minutes", oneHour = "one_hour", untilTomorrow = "until_tomorrow"
    }
    let duration: Duration?
}
struct ComputerUseIPCTimelineResumeRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCTimelineStatus
}
struct ComputerUseIPCTimelineStatusRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCTimelineStatus
}
struct ComputerUseIPCTimelineGetSettingsRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCTimelineSettings
}
struct ComputerUseIPCTimelineUpdateSettingsRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCTimelineSettings
    let settings: ComputerUseIPCTimelineSettings
}
