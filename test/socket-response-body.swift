import Foundation

@main enum SocketResponseBodyTests {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let cases = corpus["cases"] as! [[String: Any]]
        var failed = 0
        for row in cases {
            let name = row["name"] as! String
            let expected = row["expected"] as! [String: Any]
            do {
                let value = try SocketResponseBody.normalizeData(Data((row["response"] as! String).utf8), for: row["type"] as! String)
                guard let reply = expected["reply"] as? [String: Any] else {
                    print("FAIL \(name): accepted a reply that should be rejected"); failed += 1; continue
                }
                let actual = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                let expectedResult = try JSONSerialization.data(withJSONObject: reply["result"]!, options: [.sortedKeys, .fragmentsAllowed])
                guard actual == expectedResult else {
                    print("FAIL \(name): \(String(decoding: actual, as: UTF8.self)) != \(String(decoding: expectedResult, as: UTF8.self))"); failed += 1; continue
                }
                print("PASS response \(name)")
            } catch is SocketResponseSerializationFailure {
                if expected["reply"] != nil {
                    print("FAIL \(name): rejected a valid response"); failed += 1
                } else { print("PASS terminal serialization failure \(name)") }
            }
        }
        guard failed == 0 else { throw NSError(domain: "SocketResponseBodyTests", code: failed) }
    }
}
