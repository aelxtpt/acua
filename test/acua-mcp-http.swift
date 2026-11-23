import Foundation

// Unit tests for the HTTP layer under the MCP streamable HTTP transport:
// request parsing, response encoding, and the path and token gate in front
// of the MCP sessions. No socket is opened.

@main
enum AcuaMCPHTTPTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static func bytes(_ text: String) -> Data { Data(text.utf8) }

    private static func parse(_ text: String) -> Result<AcuaHTTPRequest?, AcuaHTTPParseError> {
        var parser = AcuaHTTPRequestParser()
        parser.append(bytes(text))
        return Result { try parser.next() }.mapError { $0 as! AcuaHTTPParseError }
    }

    private static func failure(_ text: String) -> AcuaHTTPParseError? {
        guard case .failure(let error) = parse(text) else { return nil }
        return error
    }

    static func main() throws {
        try parserTests()
        encodingTests()
        gateTests()
        tokenTests()
        initializeTests()
        print("\(passed) MCP HTTP tests passed")
    }

    // MARK: - Parser

    private static func parserTests() throws {
        let post = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let request = try parse(post).get()
        check("Parser_CompleteRequest_ReadsMethodAndTarget", request?.method == "POST" && request?.target == "/mcp")
        check("Parser_CompleteRequest_ReadsTheBody", request?.body == bytes("{}"))
        check("Parser_Headers_AreFoundWithoutCase", request?.header("content-type") == "application/json"
              && request?.header("HOST") == "127.0.0.1:8765")

        var split = AcuaHTTPRequestParser()
        split.append(bytes("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe"))
        check("Parser_PartialBody_WaitsForTheRest", (try? split.next()) == .some(nil))
        split.append(bytes("llo"))
        check("Parser_PartialBody_CompletesWhenTheRestArrives", (try? split.next())??.body == bytes("hello"))

        var pipelined = AcuaHTTPRequestParser()
        pipelined.append(bytes("GET /mcp HTTP/1.1\r\n\r\nDELETE /mcp HTTP/1.1\r\nMcp-Session-Id: s\r\n\r\n"))
        let first = try pipelined.next()
        let second = try pipelined.next()
        check("Parser_TwoRequestsInOneRead_AreReadInOrder",
              first?.method == "GET" && second?.method == "DELETE" && second?.header("mcp-session-id") == "s")
        check("Parser_RequestWithoutLength_HasNoBody", first?.body.isEmpty == true)
        check("Parser_AfterAllRequests_WaitsForMore", (try? pipelined.next()) == .some(nil))

        check("Parser_HeadersPastTheLimit_AreRejected",
              failure("GET /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: AcuaHTTPRequestParser.maximumHeaderBytes)) == .headersTooLarge)
        check("Parser_BodyPastTheLimit_IsRejected",
              failure("POST /mcp HTTP/1.1\r\nContent-Length: \(AcuaHTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n") == .bodyTooLarge)
        check("Parser_ChunkedBody_IsRejected",
              failure("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .unsupportedTransferEncoding)
        check("Parser_BadRequestLine_IsRejected", failure("NONSENSE\r\n\r\n") == .malformed)
        check("Parser_BadContentLength_IsRejected", failure("POST /mcp HTTP/1.1\r\nContent-Length: two\r\n\r\n") == .malformed)
        check("Parser_OtherHTTPVersion_IsRejected", failure("GET /mcp HTTP/2\r\n\r\n") == .malformed)

        check("ParseError_StatusCodes_MatchHTTP",
              AcuaHTTPParseError.headersTooLarge.statusCode == 431 && AcuaHTTPParseError.bodyTooLarge.statusCode == 413
                  && AcuaHTTPParseError.unsupportedTransferEncoding.statusCode == 501 && AcuaHTTPParseError.malformed.statusCode == 400)
    }

    // MARK: - Encoding

    private static func encodingTests() {
        let head = String(decoding: AcuaHTTPResponseEncoding.head(status: 200, headers: ["Content-Type": "application/json"],
                                                                 contentLength: 2), as: UTF8.self)
        check("Encoding_FixedLengthHead_HasStatusHeadersAndLength",
              head == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n", head)

        let stream = String(decoding: AcuaHTTPResponseEncoding.head(status: 200, headers: [:], contentLength: nil), as: UTF8.self)
        check("Encoding_StreamHead_IsChunked", stream == "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", stream)

        check("Encoding_Chunk_HasHexLength", AcuaHTTPResponseEncoding.chunk(bytes("hello world, mcp")) == bytes("10\r\nhello world, mcp\r\n"))
        check("Encoding_EmptyChunk_IsNotTheEnd", AcuaHTTPResponseEncoding.chunk(Data()).isEmpty)
        check("Encoding_LastChunk_EndsTheStream", AcuaHTTPResponseEncoding.lastChunk == bytes("0\r\n\r\n"))

        let unauthorized = String(decoding: AcuaHTTPResponseEncoding.head(status: 401, headers: [:], contentLength: 0), as: UTF8.self)
        check("Encoding_UnknownReason_StillHasAStatusLine", unauthorized.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), unauthorized)
    }

    // MARK: - Gate

    private static func request(_ target: String, authorization: String?) -> AcuaHTTPRequest {
        var headers = ["Host": "127.0.0.1:8765"]
        headers["Authorization"] = authorization
        return AcuaHTTPRequest(method: "POST", target: target, headers: headers, body: Data())
    }

    private static func gateTests() {
        let gate = AcuaMCPHTTPGate(token: "secret-token")

        check("Gate_RightPathAndToken_Passes", gate.rejection(request("/mcp", authorization: "Bearer secret-token")) == nil)
        check("Gate_QueryString_IsIgnored", gate.rejection(request("/mcp?x=1", authorization: "Bearer secret-token")) == nil)
        check("Gate_SchemeInOtherCase_Passes", gate.rejection(request("/mcp", authorization: "bearer secret-token")) == nil)

        check("Gate_OtherPath_IsNotFound", gate.rejection(request("/other", authorization: "Bearer secret-token"))?.status == 404)
        check("Gate_NoToken_IsUnauthorized", gate.rejection(request("/mcp", authorization: nil))?.status == 401)
        check("Gate_WrongToken_IsUnauthorized", gate.rejection(request("/mcp", authorization: "Bearer secret-tokem"))?.status == 401)
        check("Gate_TokenPrefix_IsUnauthorized", gate.rejection(request("/mcp", authorization: "Bearer secret"))?.status == 401)
        check("Gate_OtherScheme_IsUnauthorized", gate.rejection(request("/mcp", authorization: "Basic secret-token"))?.status == 401)
        check("Gate_Unauthorized_NamesTheBearerScheme",
              gate.rejection(request("/mcp", authorization: nil))?.headers["WWW-Authenticate"] == "Bearer")
    }

    // MARK: - Opening a session

    private static func initializeTests() {
        check("IsInitialize_InitializeRequest_OpensASession",
              AcuaMCPHTTPGate.isInitialize(bytes(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)))
        check("IsInitialize_OtherRequest_DoesNot",
              !AcuaMCPHTTPGate.isInitialize(bytes(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)))
        check("IsInitialize_InitializeWithoutID_IsANotificationAndDoesNot",
              !AcuaMCPHTTPGate.isInitialize(bytes(#"{"jsonrpc":"2.0","method":"initialize"}"#)))
        check("IsInitialize_Batch_DoesNot",
              !AcuaMCPHTTPGate.isInitialize(bytes(#"[{"jsonrpc":"2.0","id":1,"method":"initialize"}]"#)))
        check("IsInitialize_NoBody_DoesNot", !AcuaMCPHTTPGate.isInitialize(nil) && !AcuaMCPHTTPGate.isInitialize(bytes("{")))
    }

    // MARK: - Token

    private static func tokenTests() {
        let first = AcuaMCPHTTPGate.generateToken()
        let second = AcuaMCPHTTPGate.generateToken()
        check("Token_Generated_Is256BitsOfHex", first.count == 64 && first.allSatisfy(\.isHexDigit), first)
        check("Token_GeneratedTwice_Differs", first != second)
    }
}
