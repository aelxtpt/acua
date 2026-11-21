import Foundation

@main enum AdmissionTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var results = [[String: Any]]()
        for row in expected["cases"] as! [[String: Any]] {
            let restricted = row["foregroundOnly"] as! Bool
            let sender = (row["senderPID"] as! NSNumber).int32Value
            let candidate = (row["candidatePID"] as! NSNumber).int32Value
            var queries = 0
            let actual = XPCSessionAdmission.permits(foregroundOnly: restricted, senderPID: sender,
                candidatePID: { queries += 1; return candidate }())
            let expectedQueries = (row["calls"] as! [String]).filter { $0 == "pid" }.count
            let passed = actual == row["accepted"] as? Bool && queries == expectedQueries
            let name = "restricted=\(restricted) sender=\(sender) candidate=\(candidate)"
            results.append(["name": name, "passed": passed])
            print("\(passed ? "PASS" : "FAIL") XPC admission \(name)")
        }
        let report: [String: Any] = ["cases": results.count, "passed": results.allSatisfy { $0["passed"] as? Bool == true },
            "results": results, "nativeConnectionActivation": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if report["passed"] as? Bool != true { exit(1) }
    }
}
