import Foundation

@main enum SocketJSONRPCTests {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let tests = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [JSON]
        var results = [JSON]()
        // The outer handler compares deadlines as strict signed 64-bit milliseconds.
        let deadlines: [(Any?, Int64, Int?)] = [
            (nil, 100, nil), (NSNull(), 100, nil), (100, 100, nil), (101, 100, nil),
            (99, 100, -32001), (Int64.min, 100, -32001), (Int64.max, 100, nil),
            (true, 100, -32602), (100.5, 100, -32602), (UInt64.max, 100, -32602),
            (Double.infinity, 100, -32602), (Double.nan, 100, -32602), ("100", 100, -32602)]
        for (index, test) in deadlines.enumerated() {
            var observed: Int?
            do { try SocketJSONRPC.validateDeadline(test.0, nowUnixMilliseconds: test.1) }
            catch let error as SocketJSONRPC.Failure { observed = error.code }
            precondition(observed == test.2, "Deadline boundary \(index)")
            print("PASS outer deadline boundary: \(index)")
        }
        for test in tests {
            let name = test["name"] as! String, data = Data(base64Encoded: test["data"] as! String)!
            var actual: JSON = ["name": name]
            do {
                let request = try SocketJSONRPC.decode(data)
                actual["outcome"] = "decoded"; actual["kind"] = request.kind.rawValue; actual["id"] = request.id.json
                if request.kind == .close { actual["response"] = request.closeResponse }
            } catch let failure as SocketJSONRPC.Failure {
                actual["outcome"] = "error"
                actual["error"] = ["id": failure.id.json, "error": ["code": failure.code, "message": failure.message]]
            }
            let expected = test["expected"] as! JSON
            guard NSDictionary(dictionary: actual).isEqual(to: expected) else {
                fatalError("\(name): expected \(expected), received \(actual)")
            }
            results.append(actual)
            print("PASS JSON-RPC request decoder: \(name)")
        }
        if CommandLine.arguments.count > 2 {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("ALL \(tests.count) JSON-RPC REQUEST DECODER CASES PASSED")
    }
}
