import Foundation

// Timeline wire contracts and their Codable representations. Native owner and
// IPC integration are tracked separately.
typealias TimelineObservationDefaultBehavior = ComputerUseIPCTimelineObservationDefaultBehavior
enum ComputerUseIPCTimelineObservationDefaultBehavior:String,Codable {case observe;case doNotObserve="do_not_observe"}
typealias TimelineObservationRuleScope = ComputerUseIPCTimelineObservationRuleScope
enum ComputerUseIPCTimelineObservationRuleScope:String,Codable {case app,url}
struct TimelineObservationRule:Codable,Equatable,Hashable {
    var scope:TimelineObservationRuleScope
    var bundleID:String?
    var urlDomain:String?
}
struct TimelineObservationSettings:Codable,Equatable {
    var defaultApplicationBehavior:TimelineObservationDefaultBehavior
    var defaultURLBehavior:TimelineObservationDefaultBehavior
    var allowlist:[TimelineObservationRule]
    var blocklist:[TimelineObservationRule]
    static let defaults=Self(defaultApplicationBehavior:.observe,defaultURLBehavior:.observe,allowlist:[],blocklist:[])
}
struct TimelineSettings:Codable,Equatable {var observation:TimelineObservationSettings}
enum TimelineState:String,Codable {case stopped,running,paused}

struct StatusMenuState: Codable {
    struct Application: Codable {
        let id: String
        let name: String
        let bundleIdentifier: String?
        let bundleURL: String?
    }

    struct ComputerUse: Codable {
        let activeApplications: [Application]
    }

    struct HistoryAvailability: Codable {
        let lastTenMinutes: Bool
        let lastHour: Bool
        let lastDay: Bool
    }

    struct Domain: Codable {
        let domain: String
        let isExcluded: Bool
    }

    struct Session: Codable {
        let startedAt: String
        let endedAt: String?
        let canClearHistory: Bool
    }

    struct RecentApplication: Codable {
        let id: String
        let name: String
        let bundleIdentifier: String?
        let bundleURL: String?
        let isExcluded: Bool
        let lastSession: Session
        let domains: [Domain]
    }

    struct ComputerHistory: Codable {
        let state: TimelineState
        let canClearHistory: HistoryAvailability
        let recentApplications: [RecentApplication]
    }

    let computerUse: ComputerUse
    let computerHistory: ComputerHistory
}
struct TimelineStatus:Codable,Equatable {
    var state:TimelineState
    var eventStreamRootPath:String?
    var currentSegmentEventsPath:String?
    var currentSegmentMetadataPath:String?
    var suppressedEventsPath:String?
    var startedAt:Date?
    var endedAt:Date?
}
struct TimelineStartRequest:Codable,Equatable {}
struct TimelineStatusRequest:Codable,Equatable {}
struct TimelineStopRequest:Codable,Equatable {}
struct TimelineResumeRequest:Codable,Equatable {}
struct TimelineGetSettingsRequest:Codable,Equatable {}
typealias TimelinePauseDuration = TimelinePauseRequest.Duration
struct TimelinePauseRequest:Codable,Equatable {
    enum Duration:String,Codable {
        case thirtyMinutes="thirty_minutes"
        case oneHour="one_hour"
        case untilTomorrow="until_tomorrow"
    }
    var duration:Duration?
}
struct TimelineUpdateSettingsRequest:Codable,Equatable {var settings:TimelineSettings}
struct TimelineUpdateObservationPolicyRequest:Codable,Equatable {var target:TimelineObservationRule;var observe:Bool}
typealias TimelineClearHistoryScope = ComputerUseIPCTimelineClearHistoryScope
enum ComputerUseIPCTimelineClearHistoryScope:String,Codable {
    case applicationSession="application_session"
    case lastTenMinutes="last_ten_minutes"
    case lastHour="last_hour"
    case lastDay="last_day"
    case all,interval
}
struct TimelineHistoryInterval:Codable,Equatable {var start:Date;var end:Date}
struct TimelineClearHistoryRequest:Codable,Equatable {var scope:TimelineClearHistoryScope;var interval:TimelineHistoryInterval?}
