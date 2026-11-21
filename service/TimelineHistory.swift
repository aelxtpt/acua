import Foundation

struct TimelineHistoryValidationError:Error,CustomNSError,CustomStringConvertible {
    var detail:String
    static var errorDomain:String {"ComputerUseIPCXPC"}
    var errorCode:Int {-10005}
    var description:String {"Invalid Computer History clear history request: \(detail)."}
    var errorUserInfo:[String:Any] {[NSLocalizedDescriptionKey:description]}
}
enum TimelineValidatedHistoryScope:Equatable {
    case applicationSession(DateInterval)
    case interval(DateInterval)
    case lastTenMinutes,lastHour,lastDay,all

    //0x100135ADC: application-session deletion ends at min(session.end,now),
    // with its start also capped at that end. Explicit intervals are retained.
    func resolvedInterval(now:Date,calendar:Calendar)->DateInterval {
        switch self {
        case .applicationSession(let interval):
            let end=min(interval.end,now)
            return DateInterval(start:min(interval.start,end),end:end)
        case .interval(let interval):return interval
        case .lastTenMinutes:return DateInterval(start:now.addingTimeInterval(-600),end:now)
        case .lastHour:return DateInterval(start:now.addingTimeInterval(-3600),end:now)
        case .lastDay:return DateInterval(start:calendar.startOfDay(for:now),end:now)
        case .all:return DateInterval(start:.distantPast,end:now)
        }
    }
}
extension TimelineClearHistoryRequest {
    func validatedScope()throws->TimelineValidatedHistoryScope {
        if scope == .applicationSession || scope == .interval {
            guard let interval else{throw TimelineHistoryValidationError(detail:"scope '\(scope.rawValue)' requires an interval")}
            guard interval.start<interval.end else{throw TimelineHistoryValidationError(detail:"interval start must be earlier than interval end")}
            let value=DateInterval(start:interval.start,end:interval.end)
            return scope == .applicationSession ? .applicationSession(value):.interval(value)
        }
        guard interval==nil else{throw TimelineHistoryValidationError(detail:"scope '\(scope.rawValue)' does not accept an interval")}
        switch scope {
        case .lastTenMinutes:return .lastTenMinutes
        case .lastHour:return .lastHour
        case .lastDay:return .lastDay
        case .all:return .all
        case .applicationSession,.interval:preconditionFailure("Handled above")
        }
    }
}

extension TimelineValidatedHistoryScope {
    var wireName: TimelineClearHistoryScope {
        switch self {
        case .applicationSession: return .applicationSession
        case .interval: return .interval
        case .lastTenMinutes: return .lastTenMinutes
        case .lastHour: return .lastHour
        case .lastDay: return .lastDay
        case .all: return .all
        }
    }
}
