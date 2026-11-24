import Foundation
import Security

/// One HTTP/1.1 request, as `AcuaHTTPRequestParser` reads it.
struct AcuaHTTPRequest: Equatable, Sendable {
    let method: String
    /// The request target as sent, query included.
    let target: String
    let headers: [String: String]
    let body: Data

    var path: Substring {
        target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

enum AcuaHTTPParseError: Error, Equatable {
    case malformed
    case headersTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding

    var statusCode: Int {
        switch self {
        case .malformed: 400
        case .headersTooLarge: 431
        case .bodyTooLarge: 413
        case .unsupportedTransferEncoding: 501
        }
    }
}

/// Reads HTTP/1.1 requests from a byte stream. Only what MCP clients send is
/// accepted: a Content-Length body or none. Chunked request bodies are
/// refused rather than half-supported.
struct AcuaHTTPRequestParser {
    static let maximumHeaderBytes = 32 * 1024
    /// MCP requests are JSON-RPC messages; images only travel in responses.
    static let maximumBodyBytes = 8 * 1024 * 1024

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete request, or nil until more bytes arrive.
    mutating func next() throws -> AcuaHTTPRequest? {
        guard let end = buffer.range(of: Self.headerEnd) else {
            guard buffer.count <= Self.maximumHeaderBytes else { throw AcuaHTTPParseError.headersTooLarge }
            return nil
        }

        guard end.lowerBound - buffer.startIndex <= Self.maximumHeaderBytes else {
            throw AcuaHTTPParseError.headersTooLarge
        }

        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw AcuaHTTPParseError.malformed
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") else {
            throw AcuaHTTPParseError.malformed
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw AcuaHTTPParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw AcuaHTTPParseError.malformed }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let request = AcuaHTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data())
        guard request.header("Transfer-Encoding") == nil else {
            throw AcuaHTTPParseError.unsupportedTransferEncoding
        }

        let length = try Self.contentLength(request)
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else {
            return nil
        }

        let bodyEnd = bodyStart + length
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return AcuaHTTPRequest(method: request.method, target: request.target, headers: headers, body: body)
    }

    private static func contentLength(_ request: AcuaHTTPRequest) throws -> Int {
        guard let value = request.header("Content-Length") else {
            return 0
        }

        guard let length = Int(value), length >= 0 else {
            throw AcuaHTTPParseError.malformed
        }

        guard length <= maximumBodyBytes else {
            throw AcuaHTTPParseError.bodyTooLarge
        }

        return length
    }
}

/// HTTP/1.1 response bytes. A response without a known length (an SSE
/// stream) is sent chunked, so the connection can carry the next request.
enum AcuaHTTPResponseEncoding {
    static let lastChunk = Data("0\r\n\r\n".utf8)

    private static let reasons = [
        200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 409: "Conflict", 413: "Content Too Large",
        415: "Unsupported Media Type", 421: "Misdirected Request", 431: "Request Header Fields Too Large",
        500: "Internal Server Error", 501: "Not Implemented",
    ]

    /// `contentLength` nil means a chunked body follows.
    static func head(status: Int, headers: [String: String], contentLength: Int?) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Status")"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }

        if let contentLength {
            lines.append("Content-Length: \(contentLength)")
        } else {
            lines.append("Transfer-Encoding: chunked")
        }

        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// An empty chunk would end the stream, so it is not sent at all.
    static func chunk(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var chunk = Data((String(data.count, radix: 16) + "\r\n").utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }
}

/// What every request must pass before it reaches an MCP session: the one
/// MCP path and the bearer token printed at start. The SDK's transport then
/// checks Host, Origin, Accept, content type, protocol version and session.
struct AcuaMCPHTTPGate: Sendable {
    static let path = "/mcp"
    private static let tokenBytes = 32

    struct Rejection: Equatable {
        let status: Int
        let headers: [String: String]
        let message: String
    }

    let token: String

    func rejection(_ request: AcuaHTTPRequest) -> Rejection? {
        guard request.path == Self.path else {
            return Rejection(status: 404, headers: [:], message: "Not Found: MCP is served at \(Self.path)")
        }

        guard let authorization = request.header("Authorization"), Self.matches(authorization, token: token) else {
            return Rejection(status: 401, headers: ["WWW-Authenticate": "Bearer"],
                             message: "Unauthorized: send the token printed at start as Authorization: Bearer <token>")
        }

        return nil
    }

    /// Whether a POST body may open a session: one initialize request (a
    /// request has an id; initialize is never part of a batch).
    static func isInitialize(_ body: Data?) -> Bool {
        guard let body, let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }

        return message["method"] as? String == "initialize" && message["id"] != nil
    }

    /// 256 random bits as hex, made at every start and never stored.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The scheme is case-insensitive (RFC 9110); the token is compared in
    /// constant time, so a wrong guess does not reveal how much of it matched.
    private static func matches(_ authorization: String, token: String) -> Bool {
        let scheme = "bearer "
        guard authorization.count > scheme.count, authorization.prefix(scheme.count).lowercased() == scheme else {
            return false
        }

        let presented = Array(authorization.dropFirst(scheme.count).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else {
            return false
        }

        var difference: UInt8 = 0
        for (left, right) in zip(presented, expected) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
