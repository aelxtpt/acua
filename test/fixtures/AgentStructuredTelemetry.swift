import Foundation

// Structured telemetry events travel as a typed payload inside this
// envelope and are logged under one event name.
enum AgentStructuredTelemetry {
    static let sdkEventName = "__protobuf_structured_event__"

    static func envelope(parameters: [String: Any], id: UUID = UUID(), createdAt: Date = Date()) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return ["eventId": id.uuidString, "eventCreatedAt": formatter.string(from: createdAt),
                "eventType": "client", "eventParams": parameters]
    }
}
