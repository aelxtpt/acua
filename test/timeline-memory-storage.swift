import Foundation

@main struct MemoryComparison {
    static func main() throws {
        let arguments = CommandLine.arguments
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as! [String: Any]
        let payload = reference["payload"] as! [String: Any]
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cua-timeline-memory-comparison-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0, failed = 0
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }
        for (index, row) in (payload["rows"] as! [[String: Any]]).enumerated() {
            let home = root.appendingPathComponent(String(index), isDirectory: true)
            let item = row["input"] as! [String: Any]
            try prepareMemoryFixture(item, home: home)
            let store = TimelineMemorySummaryStore(memoryResourcesURL: summaryResources(home))
            defer { _ = chmod(summaryResources(home).path, 0o755) }
            for (stepIndex, expected) in (row["steps"] as! [[String: Any]]).enumerated() {
                let operation = expected["operation"] as! [String: Any]
                var actual: [String: Any] = ["operation": operation]
                do {
                    switch operation["kind"] as! String {
                    case "list":
                        actual["value"] = try store.listSummaries(sixHour: operation["sixHour"] as! Bool).map {
                            ["bucketStart": $0.bucketStart.timeIntervalSince1970,
                             "path": $0.url.path.replacingOccurrences(of: home.path, with: "$ROOT")] as [String: Any]
                        }
                    case "contains": actual["value"] = try store.containsSummaries(overlapping: summaryInterval(operation))
                    case "remove":
                        try store.removeSummaries(overlapping: summaryInterval(operation)); actual["value"] = NSNull()
                    default: fatalError("Unknown native fixture operation")
                    }
                } catch { actual["error"] = memoryError(error, home: home) }
                actual["filesystem"] = try memoryFilesystem(home)
                if try canonical(actual) == canonical(expected) { passed += 1; print("PASS summary storage", row["name"]!, "step", stepIndex) }
                else {
                    failed += 1
                    print("FAIL", row["name"]!, "step", stepIndex)
                    print("expected:", String(data: try canonical(expected), encoding: .utf8)!)
                    print("actual:", String(data: try canonical(actual), encoding: .utf8)!)
                }
            }
            _ = chmod(summaryResources(home).path, 0o755)
        }
        print("Memory storage native comparison: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
