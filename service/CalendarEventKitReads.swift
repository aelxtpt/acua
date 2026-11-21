import EventKit
import Foundation

enum CalendarReadError: Error, Equatable, CustomStringConvertible {
    case accessRequired
    case eventNotFound
    case incompleteEvent
    case incompleteCalendar

    var description: String {
        switch self {
        case .accessRequired: return "Calendar access is required"
        case .eventNotFound: return "The requested event was not found"
        case .incompleteEvent: return "EventKit returned an incomplete event"
        case .incompleteCalendar: return "EventKit returned a calendar without a source"
        }
    }
}

protocol CalendarReadBackend {
    associatedtype Event

    var hasFullAccess: Bool { get }
    func calendars() throws -> [CalendarIPCCalendar]
    func calendarIDs() -> [String]
    func listOccurrences(in range: DateInterval, calendarIDs: [String], stopAfter: Int) throws -> [Event]
    func occurrences(start: Date, end: Date) -> [Event]
    func identifier(of event: Event) -> String?
    func candidate(for event: Event) throws -> CalendarPaging.Candidate
}

struct CalendarReads<Backend: CalendarReadBackend> {
    let backend: Backend

    func listCalendars() throws -> [CalendarIPCCalendar] {
        guard backend.hasFullAccess else { throw CalendarReadError.accessRequired }
        return try backend.calendars()
    }

    func listEvents(_ request: CalendarIPCListEventsRequest, calendar: Calendar = .current) throws -> CalendarIPCEventsPage {
        guard backend.hasFullAccess else { throw CalendarReadError.accessRequired }
        let paging = try CalendarPaging(request, calendar: calendar, availableCalendarIDs: backend.calendarIDs())
        guard !paging.selectedCalendarIDs.isEmpty else { return .init(events: [], nextCursor: nil) }
        let matches = try backend.listOccurrences(in: paging.predicateRange,
                                                  calendarIDs: paging.selectedCalendarIDs, stopAfter: 501)
        try paging.validateCandidateCount(matches.count)
        return try paging.page(matches.map(backend.candidate))
    }

    func getEvent(_ request: CalendarIPCGetEventRequest) throws -> CalendarIPCEvent {
        return try backend.candidate(for: occurrence(for: request.id)).event
    }

    func occurrence(for id: CalendarIPCEventID) throws -> Backend.Event {
        guard backend.hasFullAccess else { throw CalendarReadError.accessRequired }
        guard !id.identifier.isEmpty else {
            throw CalendarPagingError.invalid("The event identifier must not be empty")
        }
        guard id.startDate.timeIntervalSinceReferenceDate.isFinite,
              id.endDate.timeIntervalSinceReferenceDate.isFinite else {
            throw CalendarPagingError.invalid("The event occurrence must have finite dates")
        }
        guard id.endDate >= id.startDate else {
            throw CalendarPagingError.invalid("The event occurrence must not end before it starts")
        }
        // The requested identifier can include a suffix after the identifier
        // returned by EventKit. Select the first matching candidate in store order.
        let matches = backend.occurrences(start: id.startDate, end: id.endDate)
        guard let event = matches.first(where: { candidate in
            backend.identifier(of: candidate).map(id.identifier.hasPrefix) ?? false
        }) else {
            throw CalendarReadError.eventNotFound
        }
        return event
    }
}

@available(macOS 14, *)
final class NativeCalendarBackend: CalendarReadBackend {
    private(set) lazy var store = makeStore()
    private let makeStore: () -> any CalendarEventStore
    private let access: () -> Bool

    init(makeStore: @escaping () -> any CalendarEventStore = { EKEventStore() },
         access: @escaping () -> Bool = { EKEventStore.authorizationStatus(for: .event) == .fullAccess }) {
        self.makeStore = makeStore
        self.access = access
    }

    var hasFullAccess: Bool { access() }

    func calendars() throws -> [CalendarIPCCalendar] {
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return try store.calendars(for: .event).map { calendar in
            guard let source = calendar.source else { throw CalendarReadError.incompleteCalendar }
            let id = calendar.calendarIdentifier
            return .init(id: id, title: calendar.title,
                         source: .init(id: source.sourceIdentifier, title: source.title),
                         allowsContentModifications: calendar.allowsContentModifications,
                         isDefault: id == defaultID)
        }
    }

    func calendarIDs() -> [String] {
        store.calendars(for: .event).map(\.calendarIdentifier)
    }

    func listOccurrences(in range: DateInterval, calendarIDs: [String], stopAfter: Int) throws -> [EKEvent] {
        let calendars = try calendarIDs.map { id in
            guard let calendar = store.calendar(withIdentifier: id) else {
                throw CalendarPagingError.calendarNotFound(id)
            }
            return calendar
        }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        var events: [EKEvent] = []
        store.enumerateEvents(matching: predicate) { event, stop in
            events.append(event)
            stop.pointee = ObjCBool(events.count >= stopAfter)
        }
        return events
    }

    func occurrences(start: Date, end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
    }

    func identifier(of event: EKEvent) -> String? { event.eventIdentifier }

    func candidate(for event: EKEvent) throws -> CalendarPaging.Candidate {
        guard let id = event.eventIdentifier, let start = event.startDate,
              let end = event.endDate, let calendar = event.calendar else { throw CalendarReadError.incompleteEvent }
        let participants = event.attendees ?? []
        let organizerIsCurrentUser = event.organizer?.isCurrentUser
        let currentStatus = organizerIsCurrentUser == false
            ? participants.first(where: \.isCurrentUser)?.participantStatus.rawValue
            : nil
        let status = currentStatus.map { raw in
            let statuses = CalendarIPCParticipantStatus.allCases
            return statuses.indices.contains(raw) ? statuses[raw] : .unknown
        }
        let attendees = participants.map { participant in
            let email = String(participant.url.absoluteString.dropFirst("mailto:".count))
            return CalendarIPCAttendee(email: email, name: email == participant.name ? nil : participant.name,
                                       isCurrentUser: participant.isCurrentUser)
        }
        let recurrence = event.recurrenceRules?.first?.description.components(separatedBy: " RRULE ").dropFirst().first
        let value = CalendarIPCEvent(id: .init(identifier: id, startDate: start, endDate: end),
            calendarID: calendar.calendarIdentifier, title: event.title, isAllDay: event.isAllDay,
            location: event.location, notes: event.notes, url: event.url, attendees: attendees,
            recurrenceRFC2445: recurrence, isCanceled: event.status == .canceled,
            currentUserParticipantStatus: status,
            isEditable: organizerIsCurrentUser != false && calendar.allowsContentModifications)
        return .init(event: value, occurrenceDate: event.occurrenceDate)
    }
}

protocol CalendarEventStore: AnyObject {
    var defaultCalendarForNewEvents: EKCalendar? { get }
    var attendeeValidator: NSObject { get }
    func calendars(for entityType: EKEntityType) -> [EKCalendar]
    func calendar(withIdentifier identifier: String) -> EKCalendar?
    func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate
    func enumerateEvents(matching predicate: NSPredicate, using block: @escaping EKEventSearchCallback)
    func events(matching predicate: NSPredicate) -> [EKEvent]
    func makeEvent() -> EKEvent
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws
}

extension EKEventStore: CalendarEventStore {
    var attendeeValidator: NSObject { self }
    func makeEvent() -> EKEvent { EKEvent(eventStore: self) }
}
