import Foundation

// IPC dates use the default Foundation Codable strategy (seconds since 2001).
// Field order also preserves the first decoding error for malformed requests.
struct ComputerUseIPCCalendarSource: Codable, Equatable, Sendable {
    var id: String
    var title: String
}

struct ComputerUseIPCCalendar: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var source: ComputerUseIPCCalendarSource
    var allowsContentModifications: Bool
    var isDefault: Bool
}

struct ComputerUseIPCCalendarEventID: Codable, Hashable, Sendable {
    var identifier: String
    var startDate: Date
    var endDate: Date
}

struct ComputerUseIPCCalendarAttendee: Codable, Hashable, Sendable {
    var email: String?
    var name: String?
    var isCurrentUser: Bool?
}

enum ComputerUseIPCCalendarParticipantStatus: String, Codable, CaseIterable, Sendable {
    case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess
}

enum ComputerUseIPCCalendarSpan: String, Codable, Sendable {
    case thisEvent, futureEvents
}

struct ComputerUseIPCCalendarEvent: Codable, Equatable, Sendable {
    var id: ComputerUseIPCCalendarEventID
    var calendarID: String
    var title: String?
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    var attendees: [ComputerUseIPCCalendarAttendee]
    var recurrenceRFC2445: String?
    var isCanceled: Bool
    var currentUserParticipantStatus: ComputerUseIPCCalendarParticipantStatus?
    var isEditable: Bool
}

struct ComputerUseIPCCalendarEventsPage: Codable, Equatable, Sendable {
    var events: [ComputerUseIPCCalendarEvent]
    var nextCursor: String?
}

struct ComputerUseIPCCalendarListCalendarsRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = [ComputerUseIPCCalendar]
}
struct ComputerUseIPCCalendarGetEventRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCCalendarEvent
    var id: ComputerUseIPCCalendarEventID
}
struct ComputerUseIPCCalendarListEventsRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCCalendarEventsPage
    var startDate: Date
    var endDate: Date
    var calendarIDs: [String]
    var limit: Int
    var cursor: String?
}
struct ComputerUseIPCCalendarCreateEventRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCCalendarEvent
    var calendarID: String?
    var title: String
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: String?
    var recurrenceRFC2445: String?
    var attendees: [ComputerUseIPCCalendarAttendee]?
}
struct ComputerUseIPCCalendarUpdateEventRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCCalendarEvent
    var id: ComputerUseIPCCalendarEventID
    var calendarID: String?
    var title: String?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool?
    var location: String?
    var notes: String?
    var url: String?
    var recurrenceRFC2445: String?
    var attendees: [ComputerUseIPCCalendarAttendee]?
    var span: ComputerUseIPCCalendarSpan
}
struct ComputerUseIPCCalendarDeleteEventRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCCalendarDeleteEventResponse
    var id: ComputerUseIPCCalendarEventID
    var span: ComputerUseIPCCalendarSpan
}
struct ComputerUseIPCCalendarDeleteEventResponse: Codable, Sendable {}

