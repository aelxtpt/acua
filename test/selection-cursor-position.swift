import Foundation
import CoreGraphics

@main struct SelectionCursorTests {
    enum Fault: Error { case scroll, position, checkpoint }
    static func main() throws {
        var rows = [[String: Any]]()
        func check(_ condition: Bool, _ name: String) {
            rows.append(["name": name, "passed": condition])
            print("\(condition ? "PASS" : "FAIL") selection cursor \(name)")
        }
        let window = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry: [(String, CGRect, CGPoint)] = [
            ("range lower-right", CGRect(x: 30, y: 40, width: 20, height: 10), CGPoint(x: 50, y: 50)),
            ("zero-width caret", CGRect(x: 30, y: 40, width: 0, height: 15), CGPoint(x: 30, y: 55)),
            ("zero-height range", CGRect(x: 30, y: 40, width: 10, height: 0), CGPoint(x: 40, y: 40)),
            ("left/top clipped", CGRect(x: -30, y: -50, width: 5, height: 10), CGPoint(x: 10, y: 20)),
            ("right/bottom clipped", CGRect(x: 100, y: 90, width: 40, height: 30), CGPoint(x: 110, y: 100)),
            ("inclusive edge", CGRect(x: 100, y: 90, width: 10, height: 10), CGPoint(x: 110, y: 100)),
            ("negative rectangle dimensions", CGRect(x: 50, y: 60, width: -10, height: -20), CGPoint(x: 50, y: 60)),
            ("infinite range clamps", .infinite, CGPoint(x: 110, y: 100))
        ]
        for (name, bounds, expected) in geometry {
            check(SelectionCursorPositioning.point(bounds: bounds, window: window) == expected, name)
        }
        check(SelectionCursorPositioning.point(bounds: CGRect(x: -480, y: -290, width: 10, height: 15),
            window: CGRect(x: -500, y: -300, width: 200, height: 100)) == CGPoint(x: -470, y: -275), "negative display coordinates")

        var trace = [String](), positions = [CGPoint](), reads = 0
        let first = CGRect(x: -50, y: -60, width: 5, height: 10)
        let updated = CGRect(x: 30, y: 40, width: 20, height: 10)
        func run(enabled: Bool = true, values: [CGRect?], scrolled: Bool = false,
                 scrollError: Bool = false, positionError: Bool = false, cancelAt: Int? = nil) -> Bool {
            trace = []; positions = []; reads = 0
            var checkpoints = 0
            do {
                try SelectionCursorPositioning.prepare(enabled: enabled, window: window, checkpoint: {
                    checkpoints += 1
                    if checkpoints == cancelAt { throw Fault.checkpoint }
                }, bounds: {
                    trace.append("bounds"); defer { reads += 1 }
                    return reads < values.count ? values[reads] : nil
                }, scroll: { frame in
                    trace.append(frame == first ? "scroll" : "wrong-scroll-rectangle")
                    if scrollError { throw Fault.scroll }; return scrolled
                }, position: { point in
                    trace.append("position"); positions.append(point)
                    if positionError { throw Fault.position }
                })
                return true
            } catch { trace.append("error"); return false }
        }
        check(run(enabled: false, values: [first]) && trace.isEmpty, "disabled skips all visual work")
        check(run(values: [nil]) && trace == ["bounds"], "missing or failed initial bounds skip visual work")
        check(run(values: [first], scrolled: false) && trace == ["bounds", "scroll", "position"] && positions == [CGPoint(x: 10, y: 20)], "unchanged scroll keeps initial bounds without requery")
        check(run(values: [first, updated], scrolled: true) && trace == ["bounds", "scroll", "bounds", "position"] && positions == [CGPoint(x: 50, y: 50)], "successful scroll requeries before positioning")
        check(run(values: [first, nil], scrolled: true) && trace == ["bounds", "scroll", "bounds", "position"] && positions == [CGPoint(x: 10, y: 20)], "failed bounds requery retains initial bounds")
        check(!run(values: [first], scrollError: true) && trace == ["bounds", "scroll", "error"], "scroll failure stops before positioning")
        check(!run(values: [first], positionError: true) && trace == ["bounds", "scroll", "position", "error"], "position failure propagates")
        check(!run(values: [first], cancelAt: 2) && trace == ["bounds", "error"], "cancellation outside optional bounds propagates")

        typealias Node = (role: String, actions: [String], settable: Bool, parent: Int?)
        func plan(_ nodes: [Int: Node], root: Int = 1) throws -> [String] {
            try ScrollToVisiblePlan.collect(from: root, identity: { $0 }, role: { nodes[$0]!.role },
                actions: { nodes[$0]!.actions }, settable: { nodes[$0]!.settable }, parent: { nodes[$0]!.parent }, checkpoint: {})
                .map { step in
                    switch step { case .action(let id): return "action:\(id)"
                    case .attribute(let id): return "attribute:\(id)"
                    case .scrollArea(let id): return "scrollArea:\(id)" }
                }
        }
        let boundary: Node = ("AXWindow", ["AXScrollToVisible"], false, nil)
        check(try plan([1: ("AXTextArea", [], false, 2), 2: boundary]).isEmpty, "window boundary excludes its own scroll action")
        check(try plan([1: ("AXTextArea", ["AXScrollToVisible"], false, 2), 2: boundary]) == ["action:1"], "supported scroll action")
        check(try plan([1: ("AXCell", [], true, 2), 2: boundary]) == ["attribute:1"], "cell scroll attribute fallback")
        check(try plan([1: ("AXCell", ["AXScrollToVisible"], true, 2), 2: boundary]) == ["action:1"], "action precedes cell attribute")
        check(try plan([1: ("AXTextArea", [], false, 2), 2: ("AXScrollArea", [], false, 3), 3: boundary]) == ["scrollArea:2"], "scroll-area fallback")
        check(try plan([1: ("AXTextArea", ["AXScrollToVisible"], false, 2), 2: ("AXButton", ["AXScrollToVisible"], false, 3), 3: boundary]) == ["action:1"], "covering child suppresses redundant ancestors")
        check(try plan([1: ("AXTextArea", ["AXScrollToVisible"], false, 2), 2: ("AXScrollArea", [], false, 3), 3: ("AXScrollArea", [], false, 4), 4: boundary]) == ["action:1", "scrollArea:3"], "clipping boundary resets ancestor coverage")
        check(try plan([1: ("AXTextArea", ["AXScrollToVisible"], false, 2), 2: ("AXGroup", ["AXScrollUpByPage"], false, 3), 3: ("AXScrollArea", [], false, 4), 4: boundary]) == ["action:1", "scrollArea:3"], "page-scrollable group resets coverage")
        check(try plan([1: ("AXTextArea", ["AXScrollToVisible"], false, 2), 2: ("AXGroup", ["AXScrollToVisible"], false, 3), 3: ("AXScrollArea", [], false, 4), 4: boundary]) == ["action:1"], "reveal-only group does not reset coverage")
        for kind in ["AXSheet", "AXMenu", "AXPopover"] {
            check(try plan([1: (kind, ["AXScrollToVisible"], true, nil)]).isEmpty, "\(kind) boundary stops collection")
        }
        do { _ = try plan([1: ("AXGroup", [], false, 2), 2: ("AXGroup", [], false, 1)]); check(false, "cycle rejected") }
        catch ScrollToVisiblePlan.Failure.cyclicAncestry { check(true, "cycle rejected") }

        let motion = CursorMotionCompletion()
        var callbacks = [String]()
        let a = motion.begin { callbacks.append("a:\($0)") }
        check(motion.isCurrent(a) && callbacks.isEmpty, "motion completion waits for actual completion")
        motion.finish(a, completed: true); motion.finish(a, completed: false)
        check(callbacks == ["a:true"] && motion.currentToken == nil, "motion finishes exactly once")
        let old = motion.begin { callbacks.append("old:\($0)") }
        let next = motion.begin { callbacks.append("next:\($0)") }
        motion.finish(old, completed: true)
        check(callbacks.last == "old:false" && motion.isCurrent(next), "replaced motion cannot finish its replacement")
        motion.finish(next, completed: false)
        check(callbacks.last == "next:false" && motion.currentToken == nil, "hide or interruption completes the current motion")
        var reentrant: UUID?
        _ = motion.begin { _ in reentrant = motion.begin(nil) }
        let superseded = motion.begin { callbacks.append("superseded:\($0)") }
        check(!motion.isCurrent(superseded) && motion.currentToken == reentrant && callbacks.last == "superseded:false", "reentrant replacement retains the newest owner")
        if let reentrant { motion.finish(reentrant, completed: true) }
        var afterFinish: UUID?
        let final = motion.begin { _ in afterFinish = motion.begin(nil) }
        motion.finish(final, completed: true)
        check(motion.currentToken == afterFinish, "completion callback may safely start a new motion")

        if CommandLine.arguments.count > 2 {
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[2]))) as! [[String: Any]]
            for row in expected {
                check(ClickableGeometry.clips(role: "AXGroup", actions: row["actions"] as! [String]) == (row["hasScrollAction"] as! Bool),
                      "scroll membership \(row["name"]!)")
            }
        }
        let passed = rows.filter { ($0["passed"] as? Bool) == true }.count
        let result: [String: Any] = ["cases": rows.count, "passed": passed, "failed": rows.count - passed,
                                   "results": rows, "nativeInput": false, "platformUIUsed": false]
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        if passed != rows.count { exit(1) }
    }
}
