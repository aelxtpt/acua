import CryptoKit
import Foundation

enum CalendarPagingError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case calendarNotFound(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        case .calendarNotFound(let id): return "Calendar with ID \(id) was not found"
        }
    }
}

// The cursor hashes the normalized filters alone. Changing the page size
// therefore does not invalidate a cursor.
struct CalendarQueryFilters: Codable, Equatable {
    var startDate: Date
    var endDate: Date
    var calendarIDs: [String]
    var timeZone: String

    func fingerprint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(self)))
    }
}

struct CalendarOccurrenceSortKey: Codable, Equatable, Comparable {
    var id: CalendarIPCEventID
    var calendarID: String
    var occurrenceDate: Date

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.id.startDate != rhs.id.startDate { return lhs.id.startDate < rhs.id.startDate }
        if lhs.id.endDate != rhs.id.endDate { return lhs.id.endDate < rhs.id.endDate }
        if lhs.id.identifier != rhs.id.identifier { return lhs.id.identifier < rhs.id.identifier }
        if lhs.calendarID != rhs.calendarID { return lhs.calendarID < rhs.calendarID }
        return lhs.occurrenceDate < rhs.occurrenceDate
    }
}

struct CalendarPageCursor: Codable, Equatable {
    var lastReturnedSortKey: CalendarOccurrenceSortKey
    var fingerprint: Data
    var formatVersion: Int

    private static let malformed = CalendarPagingError.invalid("cursor is malformed; use next_cursor returned by list_events")

    static func read(_ text: String, filters: CalendarQueryFilters) throws -> Self {
        guard let bytes = Data(base64Encoded: text),
              let cursor = try? JSONDecoder().decode(Self.self, from: bytes) else { throw malformed }
        guard cursor.formatVersion == 1 else {
            throw CalendarPagingError.invalid("cursor version is unsupported; call list_events again without a cursor")
        }
        guard try cursor.fingerprint == filters.fingerprint() else {
            throw CalendarPagingError.invalid("cursor does not match the current list_events filters")
        }
        let key = cursor.lastReturnedSortKey
        guard key.id.startDate.timeIntervalSinceReferenceDate.isFinite,
              key.id.endDate.timeIntervalSinceReferenceDate.isFinite,
              key.occurrenceDate.timeIntervalSinceReferenceDate.isFinite,
              !key.id.identifier.isEmpty, !key.calendarID.isEmpty,
              key.id.startDate <= key.id.endDate, key.id.startDate < filters.endDate,
              key.id.endDate >= filters.startDate,
              filters.calendarIDs.isEmpty || filters.calendarIDs.contains(key.calendarID) else { throw malformed }
        return cursor
    }
}

struct CalendarPaging {
    struct Candidate {
        var event: CalendarIPCEvent
        var occurrenceDate: Date?
        var key: CalendarOccurrenceSortKey {
            .init(id: event.id, calendarID: event.calendarID, occurrenceDate: occurrenceDate ?? event.id.startDate)
        }
    }

    let filters: CalendarQueryFilters
    let limit: Int
    let cursor: CalendarPageCursor?
    let selectedCalendarIDs: [String]

    init(_ request: CalendarIPCListEventsRequest, calendar: Calendar,
         availableCalendarIDs: @autoclosure () -> [String]) throws {
        let start = request.startDate, end = request.endDate
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite else {
            throw CalendarPagingError.invalid("The event range must have finite dates")
        }
        guard start <= end else {
            throw CalendarPagingError.invalid("The event range must not end before it starts")
        }
        let range: DateInterval
        if start == end {
            guard let day = calendar.dateInterval(of: .day, for: start) else {
                throw CalendarPagingError.invalid("Could not determine the calendar day for the requested date.")
            }
            range = day
        } else {
            range = DateInterval(start: start, end: end)
        }
        guard let ceiling = calendar.date(byAdding: .day, value: 31, to: range.start), range.end <= ceiling else {
            throw CalendarPagingError.invalid("The event range must not exceed 31 calendar days")
        }
        let filters = CalendarQueryFilters(startDate: range.start, endDate: range.end,
            calendarIDs: Set(request.calendarIDs).sorted(), timeZone: calendar.timeZone.identifier)
        guard request.limit > 0 else { throw CalendarPagingError.invalid("limit must be greater than zero") }
        let cursor = try request.cursor.map { try CalendarPageCursor.read($0, filters: filters) }
        let availableCalendarIDs = availableCalendarIDs()
        let available = Set(availableCalendarIDs)
        if let missing = request.calendarIDs.first(where: { !available.contains($0) }) {
            throw CalendarPagingError.calendarNotFound(missing)
        }
        self.filters = filters
        self.limit = min(request.limit, 100)
        self.cursor = cursor
        let requested = Set(filters.calendarIDs)
        selectedCalendarIDs = requested.isEmpty ? availableCalendarIDs : availableCalendarIDs.filter(requested.contains)
    }

    // Pass the selected calendars and this range to EventKit's occurrence
    // predicate. EventKit remains responsible for recurring event expansion.
    var predicateRange: DateInterval {
        DateInterval(start: max(filters.startDate, cursor?.lastReturnedSortKey.id.startDate ?? filters.startDate),
                     end: filters.endDate)
    }

    func validateCandidateCount(_ count: Int) throws {
        guard count <= 500 else {
            throw CalendarPagingError.invalid("More than 500 events match this request. No partial results were returned. Try a shorter date range or fewer calendars.")
        }
    }

    // EventKit can return the cursor occurrence again. Apply the cap before paging.
    func page(_ candidates: [Candidate]) throws -> CalendarIPCEventsPage {
        try validateCandidateCount(candidates.count)
        let after = cursor?.lastReturnedSortKey
        let ordered = candidates.filter { candidate in after.map { $0 < candidate.key } ?? true }
            .sorted { $0.key < $1.key }
        let result = ordered.prefix(limit)
        let next: String?
        if ordered.count > limit, let last = result.last {
            let value = CalendarPageCursor(lastReturnedSortKey: last.key,
                fingerprint: try filters.fingerprint(), formatVersion: 1)
            next = try JSONEncoder().encode(value).base64EncodedString()
        } else {
            next = nil
        }
        return .init(events: result.map(\.event), nextCursor: next)
    }
}
