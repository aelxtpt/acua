import Foundation

struct AgentTurnEndedNotification: Decodable, Sendable {
    let type: String
    let threadID: String
    let turnID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case threadID = "thread-id"
        case turnID = "turn-id"
    }
}

struct ComputerUseIPCTurnEndedRequest: Codable, Equatable, Sendable {
    let threadID: String
    let turnID: String?
}

enum CodexPreviousNotify {
    // Waits for /usr/bin/env and ignores its exit status.
    // The notification stays one literal argument; no shell is involved.
    static func forward(_ notification: String, previousNotify: String?) {
        guard let previousNotify,
              let data = previousNotify.data(using: .utf8),
              let command = try? JSONDecoder().decode([String].self, from: data),
              !command.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command + [notification]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Launch and previous-command decoding errors are swallowed.
        }
    }
}

enum AgentTurnEnded {
    // Finding a running service and sending are supplied by the native client.
    // This notification never launches a service.
    @MainActor static func run<Service>(
        notification: String,
        previousNotify: String?,
        findRunningService: () async throws -> Service?,
        send: (Service, AgentTurnEndedRequest) async throws -> Void,
        diagnostic: (AgentTurnEndedNotification, Error) -> Void = { _, _ in },
        forward: (String, String?) -> Void = CodexPreviousNotify.forward
    ) async {
        defer { forward(notification, previousNotify) }
        guard let data = notification.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AgentTurnEndedNotification.self, from: data),
              decoded.type == "agent-turn-complete" else { return }
        do {
            guard let service = try await findRunningService() else { return }
            try await send(service, .init(threadID: decoded.threadID, turnID: decoded.turnID))
        } catch {
            diagnostic(decoded, error)
        }
    }
}

typealias AgentTurnEndedRequest = ComputerUseIPCTurnEndedRequest
