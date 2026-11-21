import Foundation

@main enum InteractionTimingTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var rows = [[String: Any]]()
        func check(_ ok: Bool, _ name: String) {
            rows.append(["name": name, "passed": ok]); print("\(ok ? "PASS" : "FAIL") cursor timing \(name)")
        }
        for row in expected["cases"] as! [[String: Any]] {
            let progress = Double(bitPattern: UInt64(row["progressBits"] as! String, radix: 16)!)
            let distance = Double(bitPattern: UInt64(row["distanceBits"] as! String, radix: 16)!)
            let already = (row["satisfied"] as! NSNumber).intValue != 0
            let actual = CursorInteractionTiming.permitsEarlyInteraction(progress: progress, distance: distance, alreadySatisfied: already)
            check(actual == (row["ready"] as! Bool), "early-interaction predicate case \(row["name"]!)")
        }
        let owner = CursorMotionCompletion()
        var calls = [Bool]()
        let early = owner.begin({ calls.append($0) }, timing: .closeEnough)
        owner.advance(early, progress: 0.994, distance: 0)
        owner.advance(early, progress: 1, distance: 3.158)
        check(calls.isEmpty && owner.isCurrent(early), "both progress and distance are required")
        owner.advance(early, progress: 0.995, distance: 3.157)
        check(calls == [true] && owner.isCurrent(early), "readiness releases interaction while retaining visual ownership")
        owner.advance(early, progress: 1, distance: 0)
        owner.finish(early, completed: true)
        check(calls == [true] && owner.currentToken == nil, "visual finish never duplicates early readiness")
        calls = []
        let finished = owner.begin({ calls.append($0) }, timing: .finished)
        owner.advance(finished, progress: 1, distance: 0)
        check(calls.isEmpty && owner.isCurrent(finished), "finished timing does not release at the early threshold")
        owner.finish(finished, completed: true)
        check(calls == [true], "finished timing releases on actual completion")
        calls = []
        let replaced = owner.begin({ calls.append($0) }, timing: .closeEnough)
        let next = owner.begin(nil)
        owner.advance(replaced, progress: 1, distance: 0); owner.finish(replaced, completed: true)
        check(calls == [false] && owner.isCurrent(next), "replacement before readiness cancels once and stale callbacks cannot finish its successor")
        owner.finish(next, completed: true)
        calls = []
        let released = owner.begin({ calls.append($0) }, timing: .closeEnough)
        owner.advance(released, progress: 1, distance: 0)
        _ = owner.begin(nil)
        check(calls == [true], "replacement after readiness cannot send a second cancellation")
        var nested: UUID?, nestedCalls = [Bool](), outerCalls = [Bool]()
        let outer = owner.begin({ value in
            outerCalls.append(value)
            nested = owner.begin({ nestedCalls.append($0) })
        }, timing: .closeEnough)
        owner.advance(outer, progress: 1, distance: 0)
        owner.finish(outer, completed: true)
        check(outerCalls == [true] && nestedCalls.isEmpty && owner.currentToken == nested,
              "readiness callback can replace movement without losing new ownership")
        owner.finish(nested!, completed: true)
        check(nestedCalls == [true], "reentrant successor retains its completion")
        for timing: CursorInteractionTiming in [.closeEnough, .finished] {
            calls = []; let token = owner.begin({ calls.append($0) }, timing: timing)
            owner.finish(token, completed: false); owner.advance(token, progress: 1, distance: 0)
            check(calls == [false] && owner.currentToken == nil, "cancellation before readiness never becomes success \(timing)")
        }
        let passed = rows.filter { $0["passed"] as! Bool }.count
        try JSONSerialization.data(withJSONObject: ["passed": passed, "failed": rows.count - passed,
            "predicate_cases": 72, "checks": rows], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if passed != rows.count { exit(1) }
    }
}
