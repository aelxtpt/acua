import EventKit
import Foundation
import ObjectiveC

private var fieldsKey: UInt8 = 0
private var savedKey: UInt8 = 0

private func fields(_ object: NSObject) -> NSMutableDictionary {
    objc_getAssociatedObject(object, &fieldsKey) as! NSMutableDictionary
}

private func snapshot(_ object: NSObject) {
    objc_setAssociatedObject(object, &savedKey, fields(object).copy(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func fixtureClass(_ base: AnyClass, _ name: String, objects: [String],
                          writable: [String] = [], booleans: [String] = []) -> AnyClass {
    let type = objc_allocateClassPair(base, name, 0)!
    for key in objects + writable {
        let getter: @convention(block) (NSObject) -> AnyObject? = { fields($0)[key] as AnyObject? }
        precondition(class_addMethod(type, NSSelectorFromString(key), imp_implementationWithBlock(getter), "@@:"))
    }
    for key in writable {
        let setter: @convention(block) (NSObject, AnyObject?) -> Void = { fields($0)[key] = $1 }
        let name = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        precondition(class_addMethod(type, NSSelectorFromString(name), imp_implementationWithBlock(setter), "v@:@"))
    }
    for key in booleans {
        let getter: @convention(block) (NSObject) -> Bool = { fields($0)[key] as? Bool ?? false }
        precondition(class_addMethod(type, NSSelectorFromString(key), imp_implementationWithBlock(getter), "B@:"))
    }
    objc_registerClassPair(type)
    return type
}

private func fixture<T: NSObject>(_ type: AnyClass, _ data: [String: Any]) -> T {
    let result = class_createInstance(type, 0) as! T
    objc_setAssociatedObject(result, &fieldsKey, NSMutableDictionary(dictionary: data), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    // The fixture bypasses the EventKit initializer and has no store to release.
    _ = Unmanaged.passRetained(result)
    return result
}

private final class OwnedCalendarStore: NSObject, CalendarEventStore {
    private let eventType: AnyClass
    let calendar: EKCalendar
    var savedEvents: [EKEvent] = []
    var failedSave = false
    var writes: [String] = []
    private var selected: [EKCalendar]?
    private var start = Date.distantPast
    private var end = Date.distantFuture

    override init() {
        let sourceType = fixtureClass(EKSource.self, "OwnedServiceSource",
            objects: ["sourceIdentifier", "title"])
        let source: EKSource = fixture(sourceType, ["sourceIdentifier": "owned-source", "title": "Owned source"])
        let calendarType = fixtureClass(EKCalendar.self, "OwnedServiceCalendar",
            objects: ["calendarIdentifier", "title", "source"], booleans: ["allowsContentModifications"])
        calendar = fixture(calendarType, ["calendarIdentifier": "owned-calendar", "title": "Owned calendar",
                                         "source": source, "allowsContentModifications": true])
        let type = fixtureClass(EKEvent.self, "OwnedServiceEvent", objects: ["eventIdentifier", "occurrenceDate", "organizer"],
            writable: ["title", "calendar", "startDate", "endDate", "location", "structuredLocation",
                       "notes", "URL", "recurrenceRules", "attendees"], booleans: ["isAllDay"])
        eventType = type
        let allDay: @convention(block) (NSObject, Bool) -> Void = { fields($0)["isAllDay"] = $1 }
        precondition(class_addMethod(type, NSSelectorFromString("setAllDay:"), imp_implementationWithBlock(allDay), "v@:B"))
        let status: @convention(block) (NSObject) -> Int = { _ in 0 }
        precondition(class_addMethod(type, NSSelectorFromString("status"), imp_implementationWithBlock(status), "q@:"))
        let rollback: @convention(block) (NSObject) -> Void = { object in
            if let saved = objc_getAssociatedObject(object, &savedKey) as? NSDictionary {
                fields(object).setDictionary(saved as! [AnyHashable: Any])
            }
        }
        precondition(class_addMethod(type, NSSelectorFromString("rollback"), imp_implementationWithBlock(rollback), "v@:"))
        let addRule: @convention(block) (NSObject, EKRecurrenceRule) -> Void = { object, rule in
            fields(object)["recurrenceRules"] = [rule]
        }
        precondition(class_addMethod(type, NSSelectorFromString("addRecurrenceRule:"), imp_implementationWithBlock(addRule), "v@:@"))
        let validate: @convention(block) (NSObject, EKParticipant, EKCalendar) -> Bool = { _, _, _ in true }
        precondition(class_addMethod(type, NSSelectorFromString("isValidAttendee:forCalendar:"), imp_implementationWithBlock(validate), "B@:@@"))
        super.init()
    }

    var defaultCalendarForNewEvents: EKCalendar? { calendar }
    var attendeeValidator: NSObject { self }
    @objc(isValidAttendee:forCalendar:)
    func validate(_ attendee: EKParticipant, calendar: EKCalendar) -> Bool { true }

    func calendars(for entityType: EKEntityType) -> [EKCalendar] { [calendar] }
    func calendar(withIdentifier identifier: String) -> EKCalendar? { identifier == calendar.calendarIdentifier ? calendar : nil }
    func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        start = startDate
        end = endDate
        selected = calendars
        return NSPredicate(value: true)
    }
    func enumerateEvents(matching predicate: NSPredicate, using block: @escaping EKEventSearchCallback) {
        var stop = ObjCBool(false)
        for event in events(matching: predicate) {
            block(event, &stop)
            if stop.boolValue { break }
        }
    }
    func events(matching predicate: NSPredicate) -> [EKEvent] {
        savedEvents.filter { event in
            (selected?.contains(where: { $0 === event.calendar }) ?? true)
                && event.startDate < end && event.endDate >= start
        }
    }
    func makeEvent() -> EKEvent { fixture(eventType, [:]) }
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        precondition(commit)
        if failedSave { throw CocoaError(.fileWriteNoPermission) }
        if event.eventIdentifier == nil {
            fields(event)["eventIdentifier"] = "owned-\(savedEvents.count)"
            savedEvents.append(event)
        }
        snapshot(event)
        writes.append("save \(span.rawValue)")
    }
    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        precondition(commit)
        savedEvents.removeAll { $0 === event }
        writes.append("remove \(span.rawValue)")
    }
}

@main struct CalendarServiceTest {
    @MainActor
    static func main() async throws {
        guard #available(macOS 14, *) else { return }
        let store = OwnedCalendarStore()
        var permission: EKAuthorizationStatus = .denied
        var prompts = 0
        var storeLoads = 0
        let gate = CalendarPermissionGate(status: { permission }, request: {
            prompts += 1
            try await Task.sleep(for: .milliseconds(250))
            return true
        })
        let backend = NativeCalendarBackend(makeStore: { storeLoads += 1; return store }, access: { permission == .fullAccess })
        let owner = CalendarNativeOwner(backend: backend, permission: gate, locate: { title in
            if title == "Owned slow location" { try? await Task.sleep(for: .milliseconds(250)) }
            return EKStructuredLocation(title: title)
        })
        func perform(_ route: CalendarOperation.Route, _ request: Any, timeout: TimeInterval = 5) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try RequestRuntime.withRequest(["deadlineUnixMilliseconds": Date().timeIntervalSince1970 * 1000 + timeout * 1000]) {
                            try CalendarIPC.perform(route: route, request: request, owner: { owner })
                        }
                    })
                }
            }
        }
        func expect(_ code: CUErrorCode, _ route: CalendarOperation.Route, _ request: Any,
                    timeout: TimeInterval = 5) async throws {
            do {
                _ = try await perform(route, request, timeout: timeout)
                throw NSError(domain: "Expected \(code)", code: 1)
            } catch let error as ServiceError {
                try check(error.code == code, "\(route) returns \(code.rawValue)")
            }
        }

        try await expect(.couldNotGetRequestData, .createEvent, [:] as JSON)
        try await expect(.calendarPermissionsDenied, .listCalendars, NSNull())
        try check(storeLoads == 0 && prompts == 0, "denied permission leaves store and presenter untouched")
        permission = .notDetermined
        try await expect(.calendarPermissionsPending, .listCalendars, NSNull())
        try await expect(.calendarPermissionsPending, .listCalendars, NSNull())
        try check(storeLoads == 0 && prompts == 1, "pending requests share one permission prompt")
        permission = .fullAccess

        let calendars = try await perform(.listCalendars, NSNull()) as! [JSON]
        try check(calendars.count == 1 && calendars.first?["id"] as? String == "owned-calendar"
                  && calendars.first?["isDefault"] as? Bool == true, "list returns native array and default calendar")
        let start = 800_000_000.0
        let request: JSON = ["title": "Owned event", "startDate": start, "endDate": start + 600,
            "isAllDay": false, "url": "https://example.invalid", "location": "Owned hall",
            "recurrenceRFC2445": "FREQ=DAILY;COUNT=2",
            "attendees": [["email": "owned@example.invalid", "name": "Owned attendee"]]]
        let created = try await perform(.createEvent, request) as! JSON
        let id = created["id"] as! JSON
        try check(created["title"] as? String == "Owned event" && created["location"] as? String == "Owned hall"
                  && (created["attendees"] as? [JSON])?.first?["email"] as? String == "owned@example.invalid"
                  && (created["recurrenceRFC2445"] as? String)?.contains("COUNT=2") == true,
                  "create saves and projects recurrence, location and attendee")
        let page = try await perform(.listEvents, ["startDate": start - 1, "endDate": start + 3600,
                                                  "calendarIDs": ["owned-calendar"], "limit": 1]) as! JSON
        try check((page["events"] as? [JSON])?.count == 1 && page["nextCursor"] == nil, "list events reads committed fixture")
        let loaded = try await perform(.getEvent, ["id": id]) as! JSON
        try check(loaded["title"] as? String == "Owned event", "get finds the created occurrence")
        let updated = try await perform(.updateEvent, ["id": id, "startDate": start + 20, "url": "",
                                                        "attendees": [] as [JSON], "span": "futureEvents"]) as! JSON
        let movedID = updated["id"] as! JSON
        try check(movedID["endDate"] as? Double == start + 620 && updated["url"] == nil
                  && (updated["attendees"] as? [JSON])?.isEmpty == true
                  && updated["title"] as? String == "Owned event", "update shifts duration and clears explicitly supplied fields")
        store.failedSave = true
        try await expect(.unknownError, .updateEvent, ["id": movedID, "title": "Unsaved", "span": "thisEvent"])
        store.failedSave = false
        let rolledBack = try await perform(.getEvent, ["id": movedID]) as! JSON
        try check(rolledBack["title"] as? String == "Owned event", "failed update rolls back before next request")

        let slow = request.merging(["location": "Owned slow location"]) { _, new in new }
        try await expect(.unknownError, .createEvent, slow, timeout: 0.05)
        let removed = try await perform(.deleteEvent, ["id": movedID, "span": "thisEvent"]) as! JSON
        try check(removed.isEmpty && store.savedEvents.isEmpty && store.writes == ["save 0", "save 1", "remove 0"],
                  "deadline cancels pending save and delete commits with expected span")
        try await expect(.calendarInvalidRequest, .getEvent, ["id": movedID])
        try await expect(.calendarInvalidRequest, .createEvent, request.merging(["calendarID": "missing"]) { _, new in new })
        try await expect(.calendarInvalidRequest, .createEvent, request.merging(["attendees": [["name": "missing email"]]]) { _, new in new })
        try check(CalendarRecurrence.parse("FREQ=DAILY;INTERVAL=9223372036854775807") == nil,
                  "overflowing recurrence interval does not reach EventKit")
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        guard passed else { throw NSError(domain: message, code: 1) }
        print("PASS \(message)")
    }
}
