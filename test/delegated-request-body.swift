import Foundation

@main enum DelegatedCorpus {
    static func main() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: String]]
        var rows: [[String: Any]] = []
        for test in cases {
            let name = test["name"]!, type = test["type"]!, data = Data(test["input"]!.utf8)
            var row: [String: Any] = ["name": name, "type": type]
            do {
                if test["mode"] == "native" {
                    _ = try DelegatedRequestBody.decode(data, requestType: type, socket: false)
                        ?? XPCAppUsageBody.decode(data, for: DirectRequestType(rawValue: type))
                } else {
                    guard try XPCAppUsageBody.decodeSocket(data, for: DirectRequestType(rawValue: type))
                        ?? DelegatedRequestBody.decode(data, requestType: type, socket: true) != nil else { fatalError(type) }
                }
                row["outcome"] = "decoded"
            } catch {
                row["description"] = String(describing: error)
                switch error {
                case DecodingError.keyNotFound(let key, let context): row["outcome"] = "keyNotFound"; row["key"] = key.stringValue; row["path"] = context.codingPath.map(\.stringValue)
                case DecodingError.typeMismatch(_, let context): row["outcome"] = "typeMismatch"; row["path"] = context.codingPath.map(\.stringValue)
                case DecodingError.valueNotFound(_, let context): row["outcome"] = "valueNotFound"; row["path"] = context.codingPath.map(\.stringValue)
                case DecodingError.dataCorrupted(let context): row["outcome"] = "dataCorrupted"; row["path"] = context.codingPath.map(\.stringValue)
                default: row["outcome"] = "otherError"
                }
            }
            rows.append(row)
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
        let expectedRows = expected["rows"] as! [[String: Any]]
        precondition(expectedRows.count == rows.count && rows.count == 1166)
        for (actual, reference) in zip(rows, expectedRows) {
            precondition(NSDictionary(dictionary: actual).isEqual(to: reference), "Request mismatch: \(actual["name"]!)\n\(actual)\n\(reference)")
        }
        for type in Set(rows.compactMap { $0["type"] as? String }).sorted() {
            print("PASS request boundary: \(type)")
        }
        try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("ALL \(rows.count) REQUEST DECODER CASES PASSED")
    }
}
