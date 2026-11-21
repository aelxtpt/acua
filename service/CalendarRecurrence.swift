import EventKit
import Foundation

enum CalendarRecurrence {
    static func parse(_ rule: String) -> EKRecurrenceRule? {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let frequency: EKRecurrenceFrequency
        if text.contains("FREQ=DAILY") { frequency = .daily }
        else if text.contains("FREQ=WEEKLY") { frequency = .weekly }
        else if text.contains("FREQ=MONTHLY") { frequency = .monthly }
        else if text.contains("FREQ=YEARLY") { frequency = .yearly }
        else { return nil }

        let interval = value(after: "INTERVAL=", in: text).flatMap(Int.init) ?? 1
        // EventKit narrows the interval before validating it.
        guard interval > 0, interval <= Int32.max else { return nil }

        let weekdays: [String: EKWeekday] = [
            "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
            "TH": .thursday, "FR": .friday, "SA": .saturday
        ]
        let tokens = capture(#"BYDAY=([\w,]*)"#, in: text)
        var days: [EKRecurrenceDayOfWeek] = []
        for token in tokens ?? [] {
            let suffix = String(token.suffix(2))
            guard let day = weekdays[suffix] else { continue }
            let ordinal = Int(token.dropLast(2)) ?? 0
            guard ordinal <= 53, frequency != .weekly || ordinal <= 0 else { return nil }
            days.append(ordinal > 0 ? EKRecurrenceDayOfWeek(day, weekNumber: ordinal) : EKRecurrenceDayOfWeek(day))
        }

        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
            daysOfTheWeek: tokens == nil ? nil : days,
            daysOfTheMonth: numbers(#"BYMONTHDAY=([\d,-]*)"#, in: text),
            monthsOfTheYear: numbers(#"BYMONTH=([\d,]*)"#, in: text),
            weeksOfTheYear: numbers(#"BYWEEKNO=([\d,-]*)"#, in: text),
            daysOfTheYear: numbers(#"BYYEARDAY=([\d,-]*)"#, in: text),
            setPositions: numbers(#"BYSETPOS=([\d,-]*)"#, in: text),
            end: end(of: text))
    }

    private static func value(after marker: String, in text: String) -> String? {
        let parts = text.components(separatedBy: marker)
        guard parts.count > 1, let last = parts.last else { return nil }
        return last.components(separatedBy: ";").first
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, options: .reportProgress, range: range) else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)).components(separatedBy: ",")
    }

    private static func numbers(_ pattern: String, in text: String) -> [NSNumber]? {
        capture(pattern, in: text)?.map { NSNumber(value: ($0 as NSString).intValue) }
    }

    private static func end(of text: String) -> EKRecurrenceEnd? {
        if let until = value(after: "UNTIL=", in: text) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "US")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if let date = formatter.date(from: until) { return EKRecurrenceEnd(end: date) }
        }
        if let count = value(after: "COUNT=", in: text).flatMap(Int.init), count > 0 {
            return EKRecurrenceEnd(occurrenceCount: count)
        }
        return nil
    }
}
