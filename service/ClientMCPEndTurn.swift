import AppKit
import Foundation
import MCP

/// The service this helper belongs to, if it is already running.
enum AcuaRunningService {
    /// The helper's Info.plist names its service; discovery only accepts
    /// ACUA's own bundle identifiers.
    @MainActor static func find() -> NSRunningApplication? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "CUAServiceBundleIdentifier") as? String else {
            return nil
        }

        return CodexRunningService.find(serviceBundleIdentifier: identifier)
    }
}

/// The `end_turn` MCP tool. Any agent, with or without hooks, calls it when its
/// turn is over; the service then lifts a "stopped by the user" lock for the
/// apps that turn used, drops the turn's audio and closes its PIP.
struct AcuaMCPEndTurnTool: Sendable {
    enum Delivery: Equatable, Sendable {
        case delivered
        /// Nothing to release: a stop only lives in a running service.
        case serviceNotRunning
    }

    static let name = "end_turn"

    static let definition = Tool(
        name: name,
        description: """
            Call once when your turn is over, before handing control back to the user. If the user stopped \
            Computer Use during this turn, the apps stay stopped until the turn ends; the next turn can use them again. \
            Do not call it to get past a stop and keep working in the same turn. Without arguments it ends the turn \
            named in this call's _meta.x-acua-turn, or this connection's session when there is none. Pass session_id \
            alone to end a whole session, or session_id and turn_id to end one turn.
            """,
        inputSchema: .object([
            "type": "object",
            "additionalProperties": false,
            "properties": .object([
                "session_id": .object(["type": "string", "description": "Session to end. Defaults to this call's session."]),
                "turn_id": .object(["type": "string", "description": "Turn to end. Only a matching turn releases a stop."]),
            ]),
        ]),
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false))

    let send: @Sendable (AgentTurnEndedRequest) async throws -> Delivery

    func call(_ parameters: CallTool.Parameters, scope: AcuaMCPTurnScope,
              callMetadata: ComputerUseJSONRPCCodexTurnMetadata) async -> CallTool.Result {
        let arguments: AcuaEndTurnArguments

        do {
            arguments = try Self.arguments(parameters.arguments)
        } catch {
            return .init(content: [.text(String(describing: error))], isError: true)
        }

        let request = scope.endedTurn(arguments: arguments, callMetadata: callMetadata)

        do {
            let delivery = try await send(request)
            return .init(content: [.text(Self.summary(request, delivery: delivery))], isError: false)
        } catch {
            return .init(content: [.text("Could not end the turn: \(String(describing: error as NSError))")], isError: true)
        }
    }

    static func arguments(_ arguments: [String: Value]?) throws -> AcuaEndTurnArguments {
        AcuaEndTurnArguments(sessionID: try string(arguments, "session_id"), turnID: try string(arguments, "turn_id"))
    }

    private static func string(_ arguments: [String: Value]?, _ name: String) throws -> String? {
        guard let value = arguments?[name], value != .null else {
            return nil
        }

        guard let text = value.stringValue else {
            throw AcuaTurnMetadataError.endTurnArgumentIsNotAString(name)
        }

        guard !text.isEmpty else {
            throw AcuaTurnMetadataError.endTurnArgumentIsEmpty(name)
        }

        return text
    }

    private static func summary(_ request: AgentTurnEndedRequest, delivery: Delivery) -> String {
        let target = request.turnID.map { "turn \($0) of session \(request.threadID)" } ?? "session \(request.threadID)"

        switch delivery {
        case .delivered:
            return "Ended \(target)."
        case .serviceNotRunning:
            return "Ended \(target). The Computer Use service was not running, so nothing was stopped."
        }
    }

    /// Ending a turn never launches the service: a service that is not
    /// running holds no stop to release.
    static func native() -> Self {
        Self(send: { request in
            guard let service = await AcuaRunningService.find() else {
                return .serviceNotRunning
            }

            try await ClientTurnEndedTransport.send(request, pid: service.processIdentifier)
            return .delivered
        })
    }
}
