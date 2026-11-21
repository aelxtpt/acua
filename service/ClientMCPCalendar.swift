import Foundation
import MCP

struct CUAMCPCalendar: Sendable {
    let listCalendars: @Sendable (ComputerUseIPCCalendarListCalendarsRequest) async throws -> [ComputerUseIPCCalendar]
    let listEvents: @Sendable (ComputerUseIPCCalendarListEventsRequest) async throws -> ComputerUseIPCCalendarEventsPage
    let getEvent: @Sendable (ComputerUseIPCCalendarGetEventRequest) async throws -> ComputerUseIPCCalendarEvent
    let createEvent: @Sendable (ComputerUseIPCCalendarCreateEventRequest) async throws -> ComputerUseIPCCalendarEvent
    let updateEvent: @Sendable (ComputerUseIPCCalendarUpdateEventRequest) async throws -> ComputerUseIPCCalendarEvent
    let deleteEvent: @Sendable (ComputerUseIPCCalendarDeleteEventRequest) async throws -> ComputerUseIPCCalendarDeleteEventResponse

    func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = CalendarMCPArguments(parameters.arguments)
            let object: [String: Value]
            switch parameters.name {
            case "list_calendars": object = try await CalendarMCPFormatting.calendars(listCalendars(arguments.listCalendars()))
            case "list_events": object = try await CalendarMCPFormatting.page(listEvents(arguments.listEvents()))
            case "get_event": object = try await CalendarMCPFormatting.event(getEvent(arguments.getEvent()))
            case "create_event": object = try await CalendarMCPFormatting.event(createEvent(arguments.createEvent()))
            case "update_event": object = try await CalendarMCPFormatting.event(updateEvent(arguments.updateEvent()))
            case "delete_event":
                _ = try await deleteEvent(arguments.deleteEvent())
                object = ["deleted": .bool(true)]
            default: throw MCPError.invalidParams("Unknown tool: " + parameters.name)
            }
            return try CalendarMCPFormatting.result(object)
        } catch { return CalendarMCPFormatting.error(error) }
    }

    static func native() -> Self {
        .init(listCalendars: { try await ComputerUseIPCClient.sendRequest($0) },
              listEvents: { try await ComputerUseIPCClient.sendRequest($0) },
              getEvent: { try await ComputerUseIPCClient.sendRequest($0) },
              createEvent: { try await ComputerUseIPCClient.sendRequest($0) },
              updateEvent: { try await ComputerUseIPCClient.sendRequest($0) },
              deleteEvent: { try await ComputerUseIPCClient.sendRequest($0) })
    }
}
