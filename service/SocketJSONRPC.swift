import Foundation
import CoreFoundation

enum SocketJSONRPC {
    static let versionMismatchMessage = "The Computer Use server and client have a version mismatch. To use Computer Use, ask the user to relaunch their agent app so that the client will be updated to the latest version."

    // The outer handler checks expiry before resolving a route
    // or decoding its typed body. Native XPC retains its separate error model.
    static func validateDeadline(_ raw: Any?, nowUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        guard let raw, !(raw is NSNull) else { return }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.compare(NSNumber(value: number.int64Value)) == .orderedSame else {
            throw Failure(code: -32602, message: "Invalid params")
        }
        if number.int64Value < nowUnixMilliseconds {
            throw Failure(code: -32001, message: "Request deadline exceeded")
        }
    }
    enum Kind: Int { case close, ping, request, unknown }

    enum ID: Decodable {
        case integer(Int64), number(Double), string(String), null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
            else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else { throw DecodingError.typeMismatch(ID.self, .init(codingPath: decoder.codingPath, debugDescription: "Invalid JSON-RPC ID")) }
        }

        var json: Any {
            switch self {
            case .integer(let value): return NSNumber(value: value)
            case .number(let value): return NSNumber(value: value)
            case .string(let value): return value
            case .null: return NSNull()
            }
        }
    }

    struct Failure: Error {
        var id: ID = .null
        var code: Int
        var message: String
        var response: JSON { ["id": id.json, "jsonrpc": "2.0", "error": ["code": code, "message": message]] }
    }

    struct Request {
        var id: ID
        var kind: Kind
        var message: JSON
        var closeResponse: JSON { ["id": id.json, "jsonrpc": "2.0", "result": NSNull()] }
    }

    private struct Header: Decodable {
        var id: ID
        var hasID: Bool
        var jsonrpc: String?
        var method: String?
        enum CodingKeys: String, CodingKey { case id, jsonrpc, method }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            hasID = fields.contains(.id)
            id = hasID ? try fields.decode(ID.self, forKey: .id) : .null
            jsonrpc = try? fields.decode(String.self, forKey: .jsonrpc)
            method = try? fields.decode(String.self, forKey: .method)
        }
    }

    private struct Envelope<Parameters: Decodable>: Decodable { var params: Parameters? }
    private struct PingParameters: Decodable { var clientApiVersion: String? }
    private struct RequestParameters: Decodable {
        var clientApiVersion: String?
        var requestType: String
        var deadlineUnixMilliseconds: Int64?
    }

    static func decode(_ data: Data) throws -> Request {
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch DecodingError.dataCorrupted {
            throw Failure(code: -32700, message: "Parse error")
        } catch {
            throw Failure(code: -32600, message: "Invalid Request")
        }
        guard header.hasID, header.jsonrpc == "2.0", let method = header.method else {
            throw Failure(id: header.id, code: -32600, message: "Invalid Request")
        }
        let kind: Kind
        switch method {
        case "close": kind = .close
        case "ping": kind = .ping
        case "request": kind = .request
        default: kind = .unknown
        }
        do {
            switch kind {
            case .ping:
                guard try decoder.decode(Envelope<PingParameters>.self, from: data).params != nil else {
                    throw Failure(id: header.id, code: -32602, message: "Invalid params")
                }
            case .request:
                guard try decoder.decode(Envelope<RequestParameters>.self, from: data).params != nil else {
                    throw Failure(id: header.id, code: -32602, message: "Invalid params")
                }
            case .close, .unknown: break
            }
        } catch {
            throw Failure(id: header.id, code: -32602, message: "Invalid params")
        }
        guard let message = jsonObject(data) else {
            throw Failure(id: header.id, code: -32600, message: "Invalid Request")
        }
        return Request(id: header.id, kind: kind, message: message)
    }
}
