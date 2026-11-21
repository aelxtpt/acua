import Foundation
import MCP

enum CalendarMCPFormatting {
    static func result(_ object: [String: Value]) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(Value.object(object)), as: UTF8.self)
        return .init(content: [.text(text)], structuredContent: .object(object))
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .init(rawValue: 3955)
        return formatter.string(from: date)
    }
    static func attendee(_ attendee: ComputerUseIPCCalendarAttendee) -> [String: Value] {
        var object: [String: Value] = [:]
        object["email"] = attendee.email.map(Value.string)
        object["name"] = attendee.name.map(Value.string)
        object["is_current_user"] = attendee.isCurrentUser.map(Value.bool)
        return object
    }
    static func event(_ event: ComputerUseIPCCalendarEvent) -> [String: Value] {
        var object: [String: Value] = [
            "id": .object(["identifier": .string(event.id.identifier),
                "start_date": .double(event.id.startDate.timeIntervalSinceReferenceDate),
                "end_date": .double(event.id.endDate.timeIntervalSinceReferenceDate)]),
            "calendar_id": .string(event.calendarID), "is_all_day": .bool(event.isAllDay),
            "start_date": .string(iso(event.id.startDate)), "end_date": .string(iso(event.id.endDate)),
            "attendees": .array(event.attendees.map { .object(attendee($0)) }),
            "is_canceled": .bool(event.isCanceled), "is_editable": .bool(event.isEditable)
        ]
        object["title"] = event.title.map(Value.string)
        object["location"] = event.location.map(Value.string)
        object["notes"] = event.notes.map(Value.string)
        object["url"] = event.url.map { .string($0.absoluteString) }
        object["recurrence_rfc2445"] = event.recurrenceRFC2445.map(Value.string)
        object["current_user_participant_status"] = event.currentUserParticipantStatus.map { .string($0.rawValue) }
        return object
    }
    static func page(_ page: ComputerUseIPCCalendarEventsPage) -> [String: Value] {
        var calendars: [Value] = [], attendees: [Value] = [], events: [Value] = []
        var calendarRefs: [String: String] = [:]
        var attendeeRefs: [ComputerUseIPCCalendarAttendee: String] = [:]
        for event in page.events {
            let calendarRef: String
            if let known = calendarRefs[event.calendarID] { calendarRef = known }
            else {
                calendarRef = String(calendars.count)
                calendarRefs[event.calendarID] = calendarRef
                calendars.append(.object(["id": .string(event.calendarID), "local_ref": .string(calendarRef)]))
            }
            let refs = event.attendees.map { value -> Value in
                if let known = attendeeRefs[value] { return .string(known) }
                let ref = String(attendees.count)
                attendeeRefs[value] = ref
                var object = attendee(value)
                object["local_ref"] = .string(ref)
                attendees.append(.object(object))
                return .string(ref)
            }
            var object = Self.event(event)
            object.removeValue(forKey: "calendar_id")
            object.removeValue(forKey: "notes")
            object["calendar"] = .string(calendarRef)
            object["attendees"] = .array(refs)
            events.append(.object(object))
        }
        var object: [String: Value] = ["events": .array(events), "calendars": .array(calendars), "attendees": .array(attendees)]
        object["next_cursor"] = page.nextCursor.map(Value.string)
        return object
    }
    static func calendars(_ calendars: [ComputerUseIPCCalendar]) -> [String: Value] {
        ["calendars": .array(calendars.map { calendar in
            .object(["id": .string(calendar.id), "title": .string(calendar.title),
                "source": .object(["id": .string(calendar.source.id), "title": .string(calendar.source.title)]),
                "allows_content_modifications": .bool(calendar.allowsContentModifications), "is_default": .bool(calendar.isDefault)])
        })]
    }
    static func error(_ error: any Error) -> CallTool.Result {
        if case ComputerUseIPCClient.Error.calendarPermissionsPending = error {
            let message = String(describing: error)
            return .init(content: [.text(message)], structuredContent: .object(["message": .string(message)]))
        }
        return .init(content: [.text(String(describing: error))], isError: true)
    }
}
