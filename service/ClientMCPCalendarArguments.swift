import Foundation
import MCP

enum CalendarMCPArgumentError: Error, CustomStringConvertible {
    case missing(String), invalid(String)
    var description: String {
        switch self {
        case .missing(let key): "Missing argument: " + key
        case .invalid(let detail): "Invalid argument: " + detail
        }
    }
}

/// MCP validation is deliberately separate from EventKit validation. For
/// example, date ordering and recurrence semantics belong to the service.
struct CalendarMCPArguments {
    let values: [String: Value]
    init(_ values: [String: Value]?) { self.values = values ?? [:] }

    func rejectUnknown(_ allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw CalendarMCPArgumentError.invalid("unsupported argument(s): " + unknown.joined(separator: ", ")
                + "; allowed arguments: " + allowed.sorted().joined(separator: ", "))
        }
    }
    func string(_ key: String, allowEmpty: Bool = false) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let text) = value,
              allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarMCPArgumentError.invalid(key + (allowEmpty ? " must be a string" : " must be a non-empty string"))
        }
        return text
    }
    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else { throw CalendarMCPArgumentError.missing(key) }
        return value
    }
    func date(_ key: String) throws -> Date? {
        guard let text = try string(key) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .init(rawValue: 3955)
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = .init(rawValue: 1907)
        guard let date = formatter.date(from: text) else {
            throw CalendarMCPArgumentError.invalid(key + " must be an ISO-8601 date-time, such as 2026-07-08T12:00:00Z")
        }
        return date
    }
    func requiredDate(_ key: String) throws -> Date {
        guard let value = try date(key) else { throw CalendarMCPArgumentError.missing(key) }
        return value
    }
    func boolean(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case .bool(let flag) = value else { throw CalendarMCPArgumentError.invalid(key + " must be a boolean") }
        return flag
    }
    func requiredBoolean(_ key: String) throws -> Bool {
        guard let value = try boolean(key) else { throw CalendarMCPArgumentError.missing(key) }
        return value
    }
    func finiteNumber(_ key: String) throws -> Double {
        guard let value = values[key] else { throw CalendarMCPArgumentError.missing(key) }
        let number: Double
        switch value {
        case .int(let value): number = Double(value)
        case .double(let value): number = value
        default: throw CalendarMCPArgumentError.invalid(key + " must be a finite number")
        }
        guard number.isFinite else { throw CalendarMCPArgumentError.invalid(key + " must be a finite number") }
        return number
    }
    func strings(_ key: String) throws -> [String] {
        guard let value = values[key] else { return [] }
        guard case .array(let array) = value else { throw CalendarMCPArgumentError.invalid(key + " must be an array of strings") }
        return try array.map {
            guard case .string(let text) = $0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CalendarMCPArgumentError.invalid(key + " must contain only non-empty strings")
            }
            return text
        }
    }
    func limit() throws -> Int {
        guard let value = values["limit"] else { return 20 }
        guard case .int(let count) = value, (1...100).contains(count) else {
            throw CalendarMCPArgumentError.invalid("limit must be an integer between 1 and 100")
        }
        return count
    }
    func id() throws -> ComputerUseIPCCalendarEventID {
        guard let value = values["id"] else { throw CalendarMCPArgumentError.missing("id") }
        guard case .object(let object) = value else { throw CalendarMCPArgumentError.invalid("id must be an object") }
        let input = Self(object)
        try input.rejectUnknown(["identifier", "start_date", "end_date"])
        return try .init(identifier: input.requiredString("identifier"),
            startDate: Date(timeIntervalSinceReferenceDate: input.finiteNumber("start_date")),
            endDate: Date(timeIntervalSinceReferenceDate: input.finiteNumber("end_date")))
    }
    func span() throws -> ComputerUseIPCCalendarSpan {
        guard let text = try string("span") else { return .thisEvent }
        guard let span = ComputerUseIPCCalendarSpan(rawValue: text) else {
            throw CalendarMCPArgumentError.invalid("span has an unsupported value")
        }
        return span
    }
    func attendees() throws -> [ComputerUseIPCCalendarAttendee]? {
        guard let value = values["attendees"] else { return nil }
        guard case .array(let array) = value else { throw CalendarMCPArgumentError.invalid("attendees must be an array of objects") }
        return try array.map {
            guard case .object(let object) = $0 else { throw CalendarMCPArgumentError.invalid("attendees must contain only objects") }
            let input = Self(object)
            try input.rejectUnknown(["email", "name"])
            return try .init(email: input.requiredString("email"), name: input.string("name", allowEmpty: true), isCurrentUser: nil)
        }
    }

    func listCalendars() throws -> ComputerUseIPCCalendarListCalendarsRequest {
        try rejectUnknown([])
        return .init()
    }
    func listEvents() throws -> ComputerUseIPCCalendarListEventsRequest {
        try rejectUnknown(["start_date", "end_date", "calendar_ids", "limit", "cursor"])
        return try .init(startDate: requiredDate("start_date"), endDate: requiredDate("end_date"),
            calendarIDs: strings("calendar_ids"), limit: limit(), cursor: string("cursor"))
    }
    func getEvent() throws -> ComputerUseIPCCalendarGetEventRequest {
        try rejectUnknown(["id"])
        return try .init(id: id())
    }
    func createEvent() throws -> ComputerUseIPCCalendarCreateEventRequest {
        try rejectUnknown(["calendar_id", "title", "start_date", "end_date", "is_all_day", "location", "notes", "url", "recurrence_rfc2445", "attendees"])
        return try .init(calendarID: string("calendar_id"), title: requiredString("title"),
            startDate: requiredDate("start_date"), endDate: date("end_date"), isAllDay: requiredBoolean("is_all_day"),
            location: string("location", allowEmpty: true), notes: string("notes", allowEmpty: true),
            url: string("url", allowEmpty: true), recurrenceRFC2445: string("recurrence_rfc2445", allowEmpty: true), attendees: attendees())
    }
    func updateEvent() throws -> ComputerUseIPCCalendarUpdateEventRequest {
        try rejectUnknown(["id", "calendar_id", "title", "start_date", "end_date", "is_all_day", "location", "notes", "url", "recurrence_rfc2445", "attendees", "span"])
        return try .init(id: id(), calendarID: string("calendar_id"), title: string("title", allowEmpty: true),
            startDate: date("start_date"), endDate: date("end_date"), isAllDay: boolean("is_all_day"),
            location: string("location", allowEmpty: true), notes: string("notes", allowEmpty: true),
            url: string("url", allowEmpty: true), recurrenceRFC2445: string("recurrence_rfc2445", allowEmpty: true),
            attendees: attendees(), span: span())
    }
    func deleteEvent() throws -> ComputerUseIPCCalendarDeleteEventRequest {
        try rejectUnknown(["id", "span"])
        return try .init(id: id(), span: span())
    }
}
