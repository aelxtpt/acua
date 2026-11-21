import Foundation

// IPC dates use the default Foundation Codable strategy (seconds since 2001).
// Field order also preserves the first decoding error for malformed requests.
struct CalendarIPCSource: Codable, Equatable {
    var id: String
    var title: String
}

struct CalendarIPCCalendar: Codable, Equatable {
    var id: String
    var title: String
    var source: CalendarIPCSource
    var allowsContentModifications: Bool
    var isDefault: Bool
}

struct CalendarIPCEventID: Codable, Hashable {
    var identifier: String
    var startDate: Date
    var endDate: Date
}

struct CalendarIPCAttendee: Codable, Equatable {
    var email: String?
    var name: String?
    var isCurrentUser: Bool?
}

enum CalendarIPCParticipantStatus: String, Codable, CaseIterable {
    case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess
}

typealias CalendarIPCSpan = ComputerUseIPCCalendarSpan
enum ComputerUseIPCCalendarSpan: String, Codable {
    case thisEvent, futureEvents
}

struct CalendarIPCEvent: Codable, Equatable {
    var id: CalendarIPCEventID
    var calendarID: String
    var title: String?
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    var attendees: [CalendarIPCAttendee]
    var recurrenceRFC2445: String?
    var isCanceled: Bool
    var currentUserParticipantStatus: CalendarIPCParticipantStatus?
    var isEditable: Bool
}

struct CalendarIPCEventsPage: Codable, Equatable {
    var events: [CalendarIPCEvent]
    var nextCursor: String?
}

struct CalendarIPCListCalendarsRequest: Codable {}
struct CalendarIPCGetEventRequest: Codable { var id: CalendarIPCEventID }

struct CalendarIPCListEventsRequest: Codable {
    var startDate: Date
    var endDate: Date
    var calendarIDs: [String]
    var limit: Int
    var cursor: String?
}

struct CalendarIPCCreateEventRequest: Codable {
    var calendarID: String?
    var title: String
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: String?
    var recurrenceRFC2445: String?
    var attendees: [CalendarIPCAttendee]?
}

struct CalendarIPCUpdateEventRequest: Codable {
    var id: CalendarIPCEventID
    var calendarID: String?
    var title: String?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool?
    var location: String?
    var notes: String?
    var url: String?
    var recurrenceRFC2445: String?
    var attendees: [CalendarIPCAttendee]?
    var span: CalendarIPCSpan
}

struct CalendarIPCDeleteEventRequest: Codable {
    var id: CalendarIPCEventID
    var span: CalendarIPCSpan
}
