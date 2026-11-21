import Foundation

private enum Failure: Error { case press, motion, release, check(String) }
private final class Collected: @unchecked Sendable {
    let lock = NSLock()
    var values = [Int64]()
    func add(_ value: Int64) { lock.withLock { values.append(value) } }
}
@MainActor private final class Backend: EventStreamSnapshotBackend {
    typealias Element = String
    typealias Value = String
    var reads = 0, fails = false
    func supportedAttributes(of element: String) -> Set<String> { reads += 1; return ["AXTitle"] }
    func bundleIdentifier(of element: String) -> String? { nil }
    func values(of element: String, for attributes: Set<String>) throws -> [String: String] {
        if fails { throw Failure.motion }; return ["AXTitle": "fresh"]
    }
}
@main enum SynthesizedEventsTests {
    @MainActor static var results = [[String: Any]]()
    @MainActor static func check(_ condition: Bool, _ name: String) throws {
        results.append(["name": name, "passed": condition]); guard condition else { throw Failure.check(name) }
        print("PASS synthesized events \(name)")
    }
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--overflow") {
            _ = SynthesizedEventNumberSequence(initialValue: .max).next()
            fatalError("Counter overflow did not trap")
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let cases = expected["cases"] as! [[String: Any]]
        for (index, row) in cases.enumerated() {
            let sequence = SynthesizedEventNumberSequence(initialValue: (row["initial"] as! NSNumber).int64Value)
            let returned = row["returned"] as! [NSNumber]
            let actual = returned.map { _ in sequence.next() }
            // The final getter value would overflow when it equals Int64.max;
            // compare consumed values there and test the trap in a subprocess.
            let final = (row["final"] as! NSNumber).int64Value
            try check(actual == returned.map(\.int64Value) && (final == .max || sequence.next() == final), "signed counter sequence \(index)")
        }
        let processSource = SynthesizedEventNumbers.shared
        let consumerA = processSource, consumerB = processSource
        try check(consumerA.next() == 0 && consumerB.next() == 1 && SynthesizedEventNumbers.shared.next() == 2,
                  "process source and independent consumers share one incrementing sequence")
        let concurrent = SynthesizedEventNumberSequence(initialValue: 0), collected = Collected()
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in collected.add(concurrent.next()) }
        try check(collected.values.sorted() == Array(Int64(0)..<10_000) && concurrent.next() == 10_000,
                  "concurrent callers allocate each number once without resetting shared state")
        for failure in ["none", "press", "motion", "release"] {
            let sequence = SynthesizedEventNumberSequence()
            var trace = [String]()
            do {
                let result = try SynthesizedMouseGesture.drag(pressNumber: sequence.next(), nextMotionNumber: { sequence.next() },
                    press: { number in trace.append("press:\(number)"); if failure == "press" { throw Failure.press }; return number },
                    motion: { number in trace.append("motion:\(number)"); if failure == "motion" { throw Failure.motion }; return [number, number, number] },
                    release: { number in trace.append("release:\(number)"); if failure == "release" { throw Failure.release }; return number })
                try check(failure == "none" && result.down == 0 && result.motion == [1, 1, 1] && result.up == 0 && sequence.next() == 2,
                          "successful gesture consumes two identities and reuses press identity for release")
            } catch Failure.press {
                try check(trace == ["press:0"] && sequence.next() == 1, "failed press consumes only press identity")
            } catch Failure.motion {
                try check(trace == ["press:0", "motion:1"] && sequence.next() == 2, "failed motion retains consumed identities without constructing release")
            } catch Failure.release {
                try check(trace == ["press:0", "motion:1", "release:0"] && sequence.next() == 2, "failed release does not roll back or allocate another identity")
            }
        }
        let backend = Backend(), snapshots = EventStreamElementSnapshots(backend: backend)
        let base = EventStreamSnapshotTransaction<Int, String>(attributeTable: [1: ["AXTitle": "table"], 2: [:]], requestedAttributes: ["AXTitle", "AXRole"])
        let seed = EventStreamElementSnapshot(supportedAttributes: ["AXTitle"], attributes: ["AXTitle": "fallback"], transactionAttributes: Set<String>?.none)
        base.fallbackCache.store(seed, for: 1); base.fallbackCache.store(seed, for: 3)
        let view = base.rekey({ "k\($0)" }, reverse: { Int($0.dropFirst())! })
        let table = snapshots.capture("k1", transaction: view)
        try check(table.attributes == ["AXTitle": "table"] && table.transactionAttributes == ["AXTitle", "AXRole"] && backend.reads == 0,
                  "projected table still precedes shared fallback and preserves requested attributes")
        try check(snapshots.capture("k2", transaction: view).attributes.isEmpty && backend.reads == 0,
                  "present empty projected table entry remains authoritative")
        try check(snapshots.capture("k3", transaction: view).attributes == seed.attributes && backend.reads == 0,
                  "projected view reads existing source fallback without a fresh read")
        let fresh = snapshots.capture("k4", transaction: view)
        try check(fresh.attributes == ["AXTitle": "fresh"] && base.fallbackCache.snapshot(for: 4)?.attributes == fresh.attributes && backend.reads == 1,
                  "projected cache miss writes through to source transaction")
        let copy = view
        base.fallbackCache.store(seed, for: 4)
        try check(snapshots.capture("k4", transaction: copy).attributes == seed.attributes && backend.reads == 1,
                  "source cache writes are visible to all projected copies")
        copy.fallbackCache.clear()
        try check(base.fallbackCache.snapshot(for: 4) == nil && view.fallbackCache.snapshot(for: "k3") == nil,
                  "clearing a projected cache clears the same source owner")
        backend.fails = true
        _ = snapshots.capture("k5", transaction: view); let reads = backend.reads
        backend.fails = false
        try check(base.fallbackCache.snapshot(for: 5)?.attributes.isEmpty == true && snapshots.capture("k5", transaction: view).attributes.isEmpty && backend.reads == reads,
                  "failed reads remain shared cached failures rather than re-querying through another identity type")
        let separate = EventStreamSnapshotTransaction<Int, String>().rekey({ "k\($0)" }, reverse: { Int($0.dropFirst())! })
        try check(separate.fallbackCache.snapshot(for: "k5") == nil, "independent transactions do not inherit projected fallback entries")
        let twice = view.rekey({ "v" + $0 }, reverse: { String($0.dropFirst()) })
        twice.fallbackCache.store(seed, for: "vk6")
        try check(base.fallbackCache.snapshot(for: 6)?.attributes == seed.attributes,
                  "nested projection preserves one cache owner across key adapters")
        if CommandLine.arguments.count > 2 {
            let record: [String: Any] = ["passed": true, "cases": results.count, "results": results,
                "expectedGetterSequencePairs": cases.count, "concurrentAllocations": 10_000,
                "nativeEventPostingAXCaptureOrUI": false]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
