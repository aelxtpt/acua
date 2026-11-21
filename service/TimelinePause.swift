import Foundation
extension TimelinePauseDuration {
    func resumeDate(now:Date,calendar:Calendar)->Date {
        switch self {
        case .thirtyMinutes:return now.addingTimeInterval(1800)
        case .oneHour:return now.addingTimeInterval(3600)
        case .untilTomorrow:
            let tomorrow=calendar.date(byAdding:.day,value:1,to:now)!
            return calendar.date(bySettingHour:9,minute:0,second:0,of:tomorrow,
                matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward)!
        }
    }
}
