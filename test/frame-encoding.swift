import Foundation

@main
enum FrameEncodingTests {
    static func main() throws {
        var checks = 0
        func check(_ name: String, _ value: Bool) {
            precondition(value, name)
            checks += 1
            print("PASS \(name)")
        }
        func frame(_ body: Data) -> Data {
            var length = UInt32(body.count).littleEndian
            return withUnsafeBytes(of: &length) { Data($0) } + body
        }
        let encodings: [(String, String.Encoding, [UInt8])] = [
            ("utf8", .utf8, []), ("utf8-bom", .utf8, [0xEF, 0xBB, 0xBF]),
            ("utf16le", .utf16LittleEndian, []), ("utf16le-bom", .utf16LittleEndian, [0xFF, 0xFE]),
            ("utf16be", .utf16BigEndian, []), ("utf16be-bom", .utf16BigEndian, [0xFE, 0xFF]),
            ("utf32le", .utf32LittleEndian, []), ("utf32le-bom", .utf32LittleEndian, [0xFF, 0xFE, 0, 0]),
            ("utf32be", .utf32BigEndian, []), ("utf32be-bom", .utf32BigEndian, [0, 0, 0xFE, 0xFF])
        ]
        let documents = [
            ("version", #"{"jsonrpc":"2.0","id":7,"method":"version"}"#),
            ("large-id-unicode", #"{"jsonrpc":"2.0","id":9223372036854775807,"method":"version","note":"👩🏽‍💻 café\u0000"}"#),
            ("malformed", #"{"jsonrpc":"2.0","id":7,"method":"version""#)
        ]
        var rows: [JSON] = [], combined = Data(), expectedBodies: [Data] = []
        for (scenario, document) in documents {
            for (name, encoding, bom) in encodings {
                let body = Data(bom) + document.data(using: encoding)!
                let bytes = frame(body)
                let object = jsonFrameObject(body)
                // Malformed documents fail; Foundation rejects the UTF-32LE BOM and
                // ACUA keeps that rejection.
                let accepted = scenario != "malformed" && name != "utf32le-bom"
                check("\(scenario)/\(name) has the expected JSON acceptance", (object != nil) == accepted)
                if let object {
                    check("\(scenario)/\(name) preserves exact integer ID", intValue(object["id"]) == (scenario == "version" ? 7 : Int.max))
                    if scenario == "large-id-unicode" {
                        check("\(name) preserves emoji, combining accent and escaped NUL", str(object["note"]) == "👩🏽‍💻 café\0")
                    }
                }
                // Every split includes header and code-unit boundaries. The
                // framing layer must never interpret a partial Unicode scalar.
                for split in 0...bytes.count {
                    var decoder = FrameDecoder()
                    let messages = decoder.append(Data(bytes.prefix(split))) + decoder.append(Data(bytes.dropFirst(split)))
                    precondition(messages == [body] && decoder.failure == nil, "\(scenario)/\(name) split \(split)")
                }
                check("\(scenario)/\(name) preserves bytes at every fragmentation boundary", true)
                combined.append(bytes); expectedBodies.append(body)
                rows.append(["scenario": scenario, "encoding": name, "bytes": body.count, "decoded": object != nil])
            }
        }
        var grouped = FrameDecoder()
        check("mixed encodings and malformed JSON retain all frame boundaries", grouped.append(combined) == expectedBodies && grouped.failure == nil)
        var zero = FrameDecoder()
        check("zero-length frame remains a JSON error without consuming the following frame", zero.append(frame(Data()) + frame(Data("{}".utf8))) == [Data(), Data("{}".utf8)] && jsonFrameObject(Data()) == nil)
        var exact = FrameDecoder()
        let maximum = Data(repeating: 0x20, count: kMaxFrameBytes)
        check("8 MiB payload is accepted inclusively by byte count", exact.append(frame(maximum)) == [maximum] && exact.failure == nil)
        var oversized = FrameDecoder(), size = UInt32(kMaxFrameBytes + 1).littleEndian
        let header = withUnsafeBytes(of: &size) { Data($0) }
        check("oversize is rejected from the header before receiving its body", oversized.append(header).isEmpty && oversized.failure?.code == .couldNotGetRequestData)
        check("an oversized decoder remains terminal", oversized.append(frame(Data("{}".utf8))).isEmpty)
        for body in [Data([0xFF]), Data([0xFF, 0xFE, 0x7B]), Data([0, 0, 0xFE, 0xFF, 0, 0, 0]) ] {
            check("invalid or truncated encoded JSON is rejected: \(body as NSData)", jsonFrameObject(body) == nil)
        }
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("ALL \(checks) FRAME ENCODING CHECKS PASSED")
    }
}
