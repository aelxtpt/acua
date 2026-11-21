import Foundation

@main enum SenderClientMetadataTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var results = [[String: Any]]()
        func check(_ ok: Bool, _ name: String) {
            results.append(["name": name, "passed": ok])
            print("\(ok ? "PASS" : "FAIL") sender metadata \(name)")
        }
        for row in expected["cases"] as! [[String: Any]] {
            let metadata = SenderClientMetadata.appleEvent(clientType: row["rawClient"] as? String, version: row["version"] as? String)
            var kind = "absent", value: String?
            if let client = metadata.clientType {
                switch client { case .nodeRepl: kind = "nodeRepl"; case .unknown(let raw): kind = "unknown"; value = raw }
            }
            let native = row["nativeBridge"] as! Bool
            check(kind == row["kind"] as? String && value == row["value"] as? String &&
                  metadata.acceptsVersion(row["version"] as? String, ipcVersion: "AcuaComputerUseIPC-5") == row["versionOK"] as? Bool &&
                  metadata.mcpRuntime == (native ? nil : .legacyMCP) &&
                  metadata.returnsActionAppSnapshot == (row["kind"] as? String != "nodeRepl"),
                  "original parser/version decision \(row["descriptor"]!)/\(row["version"]!)")
        }
        check(SenderClientMetadata.socket.clientType == nil && SenderClientMetadata.socket.mcpRuntime == .nodeRepl &&
              SenderClientMetadata.socket.returnsActionAppSnapshot, "socket runtime is nodeRepl without claiming the node client case")
        let original = SenderRequestContext(senderPID: 41, responsibleIdentity: .init(bundleID: "owner"), ancestorIdentities: [], foregroundOnly: true)
        let copy = original.withAppleEventMetadata(clientType: "node_repl", version: SenderClientMetadata.nativeBridgeVersion)
        check(copy.senderPID == original.senderPID && copy.responsibleIdentity == original.responsibleIdentity &&
              copy.foregroundOnly && copy.clientMetadata.clientType == .nodeRepl && copy.clientMetadata.mcpRuntime == nil &&
              original.clientMetadata.clientType == nil, "metadata snapshot preserves identity and grant without mutating its source")
        let report: [String: Any] = ["passed": results.allSatisfy { $0["passed"] as? Bool == true }, "cases": results.count,
            "results": results, "originalParserAndVersionCompared": true, "wholeOriginalContextConstructorCompared": false,
            "nativeRequests": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if report["passed"] as? Bool != true { Foundation.exit(1) }
    }
}
