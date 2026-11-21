import EventKit
import Foundation

enum CalendarOperation {
    enum Route: String, CaseIterable {
        case listCalendars = "ComputerUseIPCCalendarListCalendarsRequest"
        case listEvents = "ComputerUseIPCCalendarListEventsRequest"
        case getEvent = "ComputerUseIPCCalendarGetEventRequest"
        case createEvent = "ComputerUseIPCCalendarCreateEventRequest"
        case updateEvent = "ComputerUseIPCCalendarUpdateEventRequest"
        case deleteEvent = "ComputerUseIPCCalendarDeleteEventRequest"
    }

    case listCalendars
    case listEvents(CalendarIPCListEventsRequest)
    case getEvent(CalendarIPCGetEventRequest)
    case createEvent(CalendarIPCCreateEventRequest)
    case updateEvent(CalendarIPCUpdateEventRequest)
    case deleteEvent(CalendarIPCDeleteEventRequest)

    init(route: Route, request: Any) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
            let decoder = JSONDecoder()
            switch route {
            case .listCalendars:
                _ = try decoder.decode(CalendarIPCListCalendarsRequest.self, from: data)
                self = .listCalendars
            case .listEvents:
                self = .listEvents(try decoder.decode(CalendarIPCListEventsRequest.self, from: data))
            case .getEvent:
                self = .getEvent(try decoder.decode(CalendarIPCGetEventRequest.self, from: data))
            case .createEvent:
                self = .createEvent(try decoder.decode(CalendarIPCCreateEventRequest.self, from: data))
            case .updateEvent:
                self = .updateEvent(try decoder.decode(CalendarIPCUpdateEventRequest.self, from: data))
            case .deleteEvent:
                self = .deleteEvent(try decoder.decode(CalendarIPCDeleteEventRequest.self, from: data))
            }
        } catch {
            throw ServiceError(.couldNotGetRequestData, "Could not decode \(route.rawValue)")
        }
    }

    @available(macOS 14, *)
    @MainActor
    func execute(on backend: NativeCalendarBackend,
                 locate: (String) async -> EKStructuredLocation?, checkpoint: () throws -> Void) async throws -> Data {
        let reads = CalendarReads(backend: backend)
        let encoder = JSONEncoder()
        switch self {
        case .listCalendars:
            return try encoder.encode(reads.listCalendars())
        case .listEvents(let request):
            return try encoder.encode(reads.listEvents(request))
        case .getEvent(let request):
            return try encoder.encode(reads.getEvent(request))
        case .createEvent(let request):
            return try await encoder.encode(backend.createEvent(request, locate: locate, checkpoint: checkpoint))
        case .updateEvent(let request):
            return try await encoder.encode(backend.updateEvent(request, locate: locate, checkpoint: checkpoint))
        case .deleteEvent(let request):
            try backend.deleteEvent(request, checkpoint: checkpoint)
            return try encoder.encode(CalendarIPCEmptyResponse())
        }
    }
}

private struct CalendarIPCEmptyResponse: Codable {}
