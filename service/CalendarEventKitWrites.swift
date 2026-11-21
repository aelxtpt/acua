import EventKit
import Foundation
import ObjectiveC

enum CalendarWriteError: Error, Equatable, CustomStringConvertible {
    case noDefaultCalendar
    case missingAttendeeEmail
    case attendeeCreationFailed
    case attendeeAPIUnavailable
    case invalidDate
    case invitedEvent(String)
    case readOnlyCalendar(String)
    case persistence(String)

    var description: String {
        switch self {
        case .noDefaultCalendar: return "No default calendar is available"
        case .missingAttendeeEmail: return "Attendee is missing email address"
        case .attendeeCreationFailed: return "Failed to create attendee"
        case .attendeeAPIUnavailable: return "EventKit attendee editing is unavailable"
        case .invalidDate: return "The event must have finite dates"
        case .invitedEvent(let organizer): return "Can't edit event that you were invited to; ask \(organizer) to make changes"
        case .readOnlyCalendar(let title):
            return "Can't edit event as the calendar the event belongs to (\(title)) does not allow content modifications."
        case .persistence(let description): return description
        }
    }
}

enum CalendarWriteRules {
    static func creationEnd(start: Date, end: Date?, defaultDuration: @autoclosure () -> TimeInterval) throws -> Date {
        try validateDates(start, end)
        if let end, end >= start { return end }
        let duration = defaultDuration()
        let proposed = start.addingTimeInterval(duration.isFinite && duration >= 0 ? duration : 3600)
        try validateDates(proposed, nil)
        return proposed
    }

    static var defaultDuration: TimeInterval {
        guard let settings = UserDefaults(suiteName: "com.apple.iCal") else { return 3600 }
        let key = "Default duration in minutes for new event"
        settings.register(defaults: [key: 60])
        return Double(settings.integer(forKey: key)) * 60
    }

    static func validateDates(_ start: Date?, _ end: Date?) throws {
        for date in [start, end].compactMap({ $0 }) {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw CalendarWriteError.invalidDate }
        }
    }

    static func validateOrganizer(isCurrentUser: Bool?, name: String?) throws {
        if isCurrentUser == false { throw CalendarWriteError.invitedEvent(name ?? "the organizer") }
    }

    static func validateDestination(title: String, allowsModifications: Bool) throws {
        guard allowsModifications else { throw CalendarWriteError.readOnlyCalendar(title) }
    }

    static func span(_ span: CalendarIPCSpan) -> EKSpan {
        switch span {
        case .thisEvent: return .thisEvent
        case .futureEvents: return .futureEvents
        }
    }
}

// The owner must serialize operations across suspension points, including geocoding.
@available(macOS 14, *)
extension NativeCalendarBackend {
    func createEvent(_ request: CalendarIPCCreateEventRequest,
                     locate: (String) async -> EKStructuredLocation?, checkpoint: () throws -> Void) async throws -> CalendarIPCEvent {
        guard hasFullAccess else { throw CalendarReadError.accessRequired }
        let calendar: EKCalendar
        if let id = request.calendarID {
            calendar = try calendarForWrite(id)
        } else {
            guard let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier else {
                throw CalendarWriteError.noDefaultCalendar
            }
            calendar = try calendarForWrite(defaultID)
        }
        let end = try CalendarWriteRules.creationEnd(start: request.startDate, end: request.endDate,
                                                     defaultDuration: CalendarWriteRules.defaultDuration)
        let event = store.makeEvent()
        event.calendar = calendar
        event.title = request.title
        event.startDate = request.startDate
        event.endDate = end
        event.isAllDay = request.isAllDay
        if let location = request.location {
            event.location = location
            event.structuredLocation = await locate(location)
        }
        event.notes = request.notes
        event.url = request.url.flatMap { URL(string: $0) }
        if let rule = request.recurrenceRFC2445.flatMap(CalendarRecurrence.parse) { event.addRecurrenceRule(rule) }
        if let attendees = request.attendees {
            try CalendarAttendeeEditing.assign(attendees, to: event, validatingWith: store.attendeeValidator, calendar: calendar)
        }
        try checkpoint()
        try save(event, span: .thisEvent, errorPrefix: "Failed to save event: ")
        return try candidate(for: event).event
    }

    func updateEvent(_ request: CalendarIPCUpdateEventRequest,
                     locate: (String) async -> EKStructuredLocation?, checkpoint: () throws -> Void) async throws -> CalendarIPCEvent {
        let event = try CalendarReads(backend: self).occurrence(for: request.id)
        let organizer = event.organizer
        try CalendarWriteRules.validateOrganizer(isCurrentUser: organizer?.isCurrentUser, name: organizer?.name)
        let destination = try request.calendarID.map(calendarForWrite)
        if let destination {
            try CalendarWriteRules.validateDestination(title: destination.title,
                                                        allowsModifications: destination.allowsContentModifications)
        }
        try CalendarWriteRules.validateDates(request.startDate, request.endDate)
        var saved = false
        defer { if !saved { event.rollback() } }

        if let destination { event.calendar = destination }
        if let title = request.title { event.title = title }
        if let start = request.startDate {
            let previousStart = event.startDate
            event.startDate = start
            if request.endDate == nil, let previousStart, let previousEnd = event.endDate {
                let shifted = start.addingTimeInterval(previousEnd.timeIntervalSince(previousStart))
                try CalendarWriteRules.validateDates(shifted, nil)
                event.endDate = shifted
            }
        }
        if let end = request.endDate { event.endDate = end }
        if let allDay = request.isAllDay { event.isAllDay = allDay }
        if let location = request.location {
            event.location = location
            event.structuredLocation = await locate(location)
        }
        if let notes = request.notes { event.notes = notes }
        if let url = request.url {
            if url.isEmpty { event.url = nil }
            else if let parsed = URL(string: url) { event.url = parsed }
        }
        if let rule = request.recurrenceRFC2445.flatMap(CalendarRecurrence.parse) {
            event.recurrenceRules = [rule]
        }
        if let attendees = request.attendees {
            guard let calendar = event.calendar else { throw CalendarReadError.incompleteEvent }
            try CalendarAttendeeEditing.assign(attendees, to: event, validatingWith: event, calendar: calendar)
        }
        try checkpoint()
        try save(event, span: CalendarWriteRules.span(request.span), errorPrefix: "Failed to update event: ")
        saved = true
        return try candidate(for: event).event
    }

    func deleteEvent(_ request: CalendarIPCDeleteEventRequest, checkpoint: () throws -> Void) throws {
        let event = try CalendarReads(backend: self).occurrence(for: request.id)
        try checkpoint()
        do {
            try store.remove(event, span: CalendarWriteRules.span(request.span), commit: true)
        } catch {
            throw CalendarWriteError.persistence("Failed to delete event: \(error.localizedDescription)")
        }
    }

    private func calendarForWrite(_ id: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id) else { throw CalendarPagingError.calendarNotFound(id) }
        return calendar
    }

    private func save(_ event: EKEvent, span: EKSpan, errorPrefix: String) throws {
        do { try store.save(event, span: span, commit: true) }
        catch { throw CalendarWriteError.persistence(errorPrefix + error.localizedDescription) }
    }
}

enum CalendarAttendeeEditing {
    static func assign(_ values: [CalendarIPCAttendee], to event: EKEvent,
                       validatingWith receiver: NSObject, calendar: EKCalendar) throws {
        let setter = NSSelectorFromString("setAttendees:")
        guard event.responds(to: setter), let setterIMP = event.method(for: setter) else {
            throw CalendarWriteError.attendeeAPIUnavailable
        }
        var attendees: [EKParticipant] = []
        if !values.isEmpty {
            let selector = NSSelectorFromString("isValidAttendee:forCalendar:")
            guard receiver.responds(to: selector), let validatorIMP = receiver.method(for: selector) else {
                throw CalendarWriteError.attendeeAPIUnavailable
            }
            typealias Validator = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
            let validate = unsafeBitCast(validatorIMP, to: Validator.self)
            for value in values {
                let attendee = try makeAttendee(value)
                if validate(receiver, selector, attendee, calendar) { attendees.append(attendee) }
            }
        }
        typealias Setter = @convention(c) (AnyObject, Selector, NSArray) -> Void
        unsafeBitCast(setterIMP, to: Setter.self)(event, setter, attendees as NSArray)
    }

    static func makeAttendee(_ value: CalendarIPCAttendee) throws -> EKParticipant {
        guard let email = value.email else { throw CalendarWriteError.missingAttendeeEmail }
        let factory = NSSelectorFromString("attendeeWithName:emailAddress:phoneNumber:url:")
        guard let type = NSClassFromString("EKAttendee"),
              let method = class_getClassMethod(type, factory) else { throw CalendarWriteError.attendeeAPIUnavailable }
        typealias Factory = @convention(c) (AnyObject, Selector, NSString?, NSString, NSString?, NSURL?) -> Unmanaged<AnyObject>?
        let create = unsafeBitCast(method_getImplementation(method), to: Factory.self)
        let url = URL(string: "mailto:" + email) as NSURL?
        guard let attendee = create(type as AnyObject, factory, value.name as NSString?, email as NSString, nil, url)?
            .takeUnretainedValue() as? EKParticipant else { throw CalendarWriteError.attendeeCreationFailed }
        return attendee
    }
}
