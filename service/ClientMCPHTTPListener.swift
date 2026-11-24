import Foundation
import MCP
import Network
import os

/// How an MCP server command talks to its client.
enum AcuaMCPTransport: Sendable, Equatable {
    /// Newline-delimited JSON-RPC on stdin and stdout, as MCP hosts start it.
    case stdio
    /// MCP streamable HTTP on 127.0.0.1; 0 picks a free port.
    case http(port: UInt16)
}

/// The MCP sessions of one HTTP server. Each session is its own MCP server,
/// with its own domain backend and turn session, as one stdio process is.
actor AcuaMCPHTTPSessions {
    typealias MakeSession = @Sendable () async throws -> (Server, StatefulHTTPServerTransport)

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
    }

    private var sessions: [String: Session] = [:]
    private let makeSession: MakeSession

    init(makeSession: @escaping MakeSession) {
        self.makeSession = makeSession
    }

    var count: Int { sessions.count }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let id = request.header(HTTPHeaderName.sessionID) {
            return await handle(request, session: id)
        }

        // Only an initialize request opens a session. A fresh transport has
        // no session to check, so anything else would be answered by a
        // throwaway server instead of being refused.
        guard request.method.uppercased() == "POST", AcuaMCPHTTPGate.isInitialize(request.body) else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: Mcp-Session-Id header is required"))
        }

        let server: Server
        let transport: StatefulHTTPServerTransport
        do {
            (server, transport) = try await makeSession()
        } catch {
            return .error(statusCode: 500, .internalError("Could not start an MCP session: \(error)"))
        }

        let response = await transport.handleRequest(request)
        guard let id = response.headers[HTTPHeaderName.sessionID] else {
            await server.stop()
            return response
        }

        sessions[id] = Session(server: server, transport: transport)
        return response
    }

    private func handle(_ request: HTTPRequest, session id: String) async -> HTTPResponse {
        guard let session = sessions[id] else {
            return .error(statusCode: 404, .invalidRequest("Not Found: no such MCP session; initialize a new one"))
        }

        let response = await session.transport.handleRequest(request)
        guard request.method.uppercased() == "DELETE", response.statusCode == 200 else {
            return response
        }

        sessions.removeValue(forKey: id)
        await session.server.stop()
        return response
    }
}

/// Serves MCP streamable HTTP on the loopback interface only. ACUA serves
/// the machine it runs on; an agent whose backend runs elsewhere brings its
/// own relay (an SSH tunnel, for example) to this port.
final class AcuaMCPHTTPListener: @unchecked Sendable {
    private let listener: NWListener
    private let gate: AcuaMCPHTTPGate
    private let sessions: AcuaMCPHTTPSessions
    private let queue = DispatchQueue(label: "com.aex.computeruse.mcp-http")

    init(port: UInt16, gate: AcuaMCPHTTPGate, sessions: AcuaMCPHTTPSessions) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        self.gate = gate
        self.sessions = sessions
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [gate, sessions, queue] connection in
            AcuaMCPHTTPConnection(connection, gate: gate, sessions: sessions, queue: queue).start()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Result<UInt16, Error>) -> Void = { result in
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

/// One TCP connection: requests are answered one at a time, each response in
/// full (an SSE stream until the transport ends it) before the next is read.
private final class AcuaMCPHTTPConnection: @unchecked Sendable {
    private static let readSize = 64 * 1024
    private let connection: NWConnection
    private let gate: AcuaMCPHTTPGate
    private let sessions: AcuaMCPHTTPSessions
    private let queue: DispatchQueue

    init(_ connection: NWConnection, gate: AcuaMCPHTTPGate, sessions: AcuaMCPHTTPSessions, queue: DispatchQueue) {
        self.connection = connection
        self.gate = gate
        self.sessions = sessions
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        Task { await serve() }
    }

    private func serve() async {
        var parser = AcuaHTTPRequestParser()
        defer { connection.cancel() }

        while true {
            let request: AcuaHTTPRequest
            do {
                guard let next = try parser.next() else {
                    guard let data = await receive() else { return }
                    parser.append(data)
                    continue
                }
                request = next
            } catch let error as AcuaHTTPParseError {
                _ = await sendFixed(status: error.statusCode, headers: ["Connection": "close", "Content-Type": "text/plain"],
                                    body: Data("\(error)\n".utf8))
                return
            } catch {
                return
            }

            guard await respond(request) else { return }
        }
    }

    /// False when the connection can no longer be used.
    private func respond(_ request: AcuaHTTPRequest) async -> Bool {
        if let rejection = gate.rejection(request) {
            var headers = rejection.headers
            headers["Content-Type"] = "text/plain"
            return await sendFixed(status: rejection.status, headers: headers, body: Data((rejection.message + "\n").utf8))
        }

        let mcpRequest = HTTPRequest(method: request.method, headers: request.headers, body: request.body.isEmpty ? nil : request.body)
        let response = await sessions.handle(mcpRequest)

        guard case .stream(let stream, let headers) = response else {
            return await sendFixed(status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
        }

        guard await send(AcuaHTTPResponseEncoding.head(status: response.statusCode, headers: headers, contentLength: nil)) else {
            return false
        }

        do {
            for try await event in stream {
                guard await send(AcuaHTTPResponseEncoding.chunk(event)) else { return false }
            }
        } catch {
            Logger(subsystem: "com.aex.computeruse.client", category: "MCPHTTP")
                .error("MCP SSE stream ended with an error: \(String(describing: error), privacy: .public)")
        }

        return await send(AcuaHTTPResponseEncoding.lastChunk)
    }

    private func sendFixed(status: Int, headers: [String: String], body: Data) async -> Bool {
        var data = AcuaHTTPResponseEncoding.head(status: status, headers: headers, contentLength: body.count)
        data.append(body)
        return await send(data)
    }

    private func send(_ data: Data) async -> Bool {
        guard !data.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    /// nil once the client closed the connection or it failed.
    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }

                guard error == nil, !isComplete else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: Data())
            }
        }
    }
}

/// `--http PORT`: one listener for one server, until the process is stopped.
enum AcuaMCPHTTPServing {
    static let sessionPrefix = "acua-http-"

    static func run(port: UInt16, serverName: String, makeSession: @escaping AcuaMCPHTTPSessions.MakeSession) async throws {
        let token = AcuaMCPHTTPGate.generateToken()
        let listener = try AcuaMCPHTTPListener(port: port, gate: AcuaMCPHTTPGate(token: token),
                                               sessions: AcuaMCPHTTPSessions(makeSession: makeSession))
        let bound = try await listener.start()

        // Standard error, so a relay can read it; the token is never stored.
        let announcement = """
            \(serverName) MCP over HTTP: http://127.0.0.1:\(bound)\(AcuaMCPHTTPGate.path)
            Token: \(token)

            """
        FileHandle.standardError.write(Data(announcement.utf8))

        // Served until the process is stopped (SIGTERM or SIGINT).
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
