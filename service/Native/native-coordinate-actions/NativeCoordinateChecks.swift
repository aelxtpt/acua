import AppKit
import ApplicationServices
import Foundation

private enum CoordinateCheckFailure: Error { case injected }
@MainActor private final class CoordinateActionFixture: ControllerCoordinateClickBackend {
    typealias Target = Bool
    typealias Cache = String
    typealias AppSnapshot = String
    var position = ControllerScaledCursorPosition(x: 91, y: 92)
    var scale: CGFloat = 2, origin = CGPoint(x: 100, y: 200)
    var menu = false, fail: String?, mutateAfterMove = false
    var trace: [String] = [], points: [CGPoint] = [], receivedDestination: CGPoint?, receivedKey: ControllerHeldClickKey?
    var needsUISettleBeforeAppSnapshot = false
    func global(_ position: ControllerScaledCursorPosition) -> CGPoint { trace.append("global"); return position.global(scale: scale, origin: origin) }
    func target(at point: CGPoint) throws -> Bool { trace.append("target"); points.append(point); try failure("target"); return menu }
    func requireAllowed(_ target: Bool) throws { trace.append("security"); try failure("security") }
    func cursorWindowID(_ target: Bool) throws -> UInt32 { trace.append("window"); try failure("window"); return target ? 73 : 51 }
    func prepareCursor(at point: CGPoint, above windowID: UInt32, drag: Bool, animated: Bool) async {
        trace.append("cursor:\(windowID):\(drag):\(animated)"); points.append(point)
        if mutateAfterMove { position = .init(x: 7, y: 11); scale = 3; origin = .init(x: -20, y: -30) }
        await Task.yield()
    }
    func isMenu(_ target: Bool) -> Bool { target }
    func movePhysical(at point: CGPoint, target: Bool) async throws { trace.append("physical"); points.append(point); try failure("physical") }
    func pressMenu(_ target: Bool) throws { trace.append("menu"); try failure("menu") }
    func click(_ target: Bool, destination: CGPoint?, options: ControllerCoordinateClickParameters, key: ControllerHeldClickKey) async throws {
        trace.append("click"); receivedDestination = destination; receivedKey = key; try failure("click")
    }
    func settle() async throws -> String? { trace.append("settle"); try failure("settle"); return "owned cache" }
    func capture(cache: String?) async throws -> String { trace.append("capture:\(cache ?? "nil")"); try failure("capture"); return "owned appSnapshot" }
    private func failure(_ stage: String) throws { if fail == stage { throw CoordinateCheckFailure.injected } }
}

@MainActor enum NativeCoordinateChecks {
    static func run(output: URL, corpus: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let exact = ControllerScaledCursorPosition(x: 9_007_199_254_740_993, y: Int64.min)
        check("raw screenshot coordinates preserve signed Int64 beyond floating precision", exact.x == 9_007_199_254_740_993 && exact.y == Int64.min)
        check("global mapping applies scale then visible origin without clipping", ControllerScaledCursorPosition(x: -3, y: 11).global(scale: 2, origin: .init(x: -100, y: 20)) == CGPoint(x: -106, y: 42))
        for menu in [false, true] {
            let f = CoordinateActionFixture(); f.menu = menu; f.mutateAfterMove = true
            let result = try await ControllerCoordinateClick(backend: f).click(.init(position: .init(x: 4, y: 5), destination: .init(x: 30, y: 40), button: 31, count: -3, animateCursor: false))
            check("\(menu ? "menu" : "ordinary") captures after action with exact cache", result == "owned appSnapshot" && f.trace.suffix(2) == ["settle", "capture:owned cache"] && !f.needsUISettleBeforeAppSnapshot)
            check("\(menu ? "menu" : "ordinary") creates cursor despite animation disabled with captured window identity", f.trace.contains("cursor:\(menu ? 73 : 51):true:false") && f.points.prefix(2) == [CGPoint(x: 108, y: 210), CGPoint(x: 108, y: 210)])
            if menu {
                check("menu bypasses movement and click despite drag and invalid mouse count", f.trace.contains("menu") && !f.trace.contains("physical") && !f.trace.contains("click"))
            } else {
                check("physical movement rereads owner geometry after awaited cursor move", f.points.last == CGPoint(x: 1, y: 3))
                check("drag destination retains geometry sampled before start replacement", f.receivedDestination == CGPoint(x: 160, y: 280))
            }
        }
        do {
            let f = CoordinateActionFixture()
            let result = try await ControllerCoordinateClick(backend: f).click(.init(returnAppSnapshot: false))
            check("missing start defaults to zero and defers settle without capture", result == nil && f.position == .zero && f.needsUISettleBeforeAppSnapshot && !f.trace.contains("settle") && f.points.first == CGPoint(x: 100, y: 200))
        }
        for stage in ["target", "security", "window", "physical", "click", "settle", "capture"] {
            let f = CoordinateActionFixture(); f.fail = stage
            var failed = false
            do { _ = try await ControllerCoordinateClick(backend: f).click(.init(position: .init(x: 1, y: 2))) }
            catch CoordinateCheckFailure.injected { failed = true }
            let boundary = stage == "capture" ? "capture:owned cache" : stage
            check("\(stage) failure preserves error and stops later effects", failed && f.trace.last == boundary && !f.needsUISettleBeforeAppSnapshot)
        }
        for key in ["unknown-key", "a+b", "ctrl a"] {
            let f = CoordinateActionFixture()
            var failed = false
            do { _ = try await ControllerCoordinateClick(backend: f).click(.init(position: .zero, key: key)) } catch { failed = true }
            check("invalid held key \(key) leaves stored cursor and target untouched", failed && f.position == .init(x: 91, y: 92) && f.trace.isEmpty)
        }
        for key in ["a", "ctrl", "ctrl+a"] {
            let f = CoordinateActionFixture(); f.menu = true
            var failed = false
            do { _ = try await ControllerCoordinateClick(backend: f).click(.init(key: key)) }
            catch ControllerCoordinateClickFailure.unsupportedMenuAction { failed = true }
            check("menu rejects held key \(key) after cursor positioning without pressing", failed && f.trace.last == "cursor:73:false:true" && !f.trace.contains("menu"))
        }
        do {
            let f = CoordinateActionFixture(); f.menu = true
            var failed = false
            do { _ = try await ControllerCoordinateClick(backend: f).click(.init(hold: .zero)) }
            catch ControllerCoordinateClickFailure.unsupportedMenuAction { failed = true }
            check("menu rejects explicit zero hold", failed && !f.trace.contains("menu"))
        }
        for interval: Duration? in [nil, .milliseconds(50)] {
            var posts: [Int] = [], waits: [Duration] = [], states: [Bool] = []
            let sender = ControllerCoordinateClickSender<Int>(isDown: { $0 == 0 }, post: { posts.append($0) }, cursor: { states.append($0) }, wait: { waits.append($0) })
            try await sender.send([0, 1, 2, 3, 4], hold: nil, interval: interval)
            check("\(interval == nil ? "drag" : "click") pacing has no final wait and one cursor pre-down wait", posts == [0, 1, 2, 3, 4] && states == [true, false, false, false, false] && waits == Array(repeating: .milliseconds(50), count: interval == nil ? 1 : 5))
        }
        do {
            var posts: [Int] = [], waits: [Duration] = []
            let sender = ControllerCoordinateClickSender<Int>(isDown: { $0 == 0 }, post: { posts.append($0) }, cursor: nil, wait: { waits.append($0); throw CoordinateCheckFailure.injected })
            try await sender.send([0, 1, 2], hold: .milliseconds(9), interval: nil)
            check("drag explicit hold is only post-down delay and its failure is suppressed", posts == [0, 1, 2] && waits == [.milliseconds(9)])
        }
        do {
            var posts: [Int] = [], states: [Bool] = []; var failed = false
            let sender = ControllerCoordinateClickSender<Int>(isDown: { $0 == 0 }, post: { posts.append($0) }, cursor: { states.append($0) }, wait: { _ in throw CoordinateCheckFailure.injected })
            do { try await sender.send([0, 1], hold: nil, interval: nil) } catch CoordinateCheckFailure.injected { failed = true }
            check("cursor pre-down failure propagates without posting or fabricated cursor release", failed && posts.isEmpty && states == [true])
        }
        var parentReads = 0
        let inside = ControllerInsideWebView.test(0, role: { $0 == 2 ? "AXWebArea" : "AXGroup" }, parent: { parentReads += 1; return $0 < 3 ? $0 + 1 : nil })
        check("inside web view traverses inclusive chain and stops at the first AXWebArea", inside && parentReads == 3)
        parentReads = 0
        check("inside web view includes the element itself", ControllerInsideWebView.test(0, role: { _ in "AXWebArea" }, parent: { _ in parentReads += 1; return nil }) && parentReads == 1)
        check("chain without AXWebArea is outside a web view", !ControllerInsideWebView.test(0, role: { _ in "AXGroup" }, parent: { $0 < 3 ? $0 + 1 : nil }))
        parentReads = 0
        check("malformed parent cycle stops at the depth bound", !ControllerInsideWebView.test(0, role: { _ in "AXGroup" }, parent: { n in parentReads += 1; return n }) && parentReads == 301)
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus)) as! [String: Any]
        let sequence = SynthesizedEventNumberSequence()
        let factory = ControllerNativeCoordinateEvents(numbers: sequence, setWindowLocation: { _, _ in preconditionFailure("No bounds supplied") })
        var compared = 0
        for row in golden["cases"] as! [[String: Any]] {
            func point(_ key: String) -> CGPoint { let a = row[key] as! [Double]; return .init(x: a[0], y: a[1]) }
            let events = try factory.click(at: point("start"), destination: point("end"), button: (row["button"] as! NSNumber).uint32Value, count: row["count"] as! Int, flags: (row["flags"] as! NSNumber).uint64Value, windowID: (row["window"] as! NSNumber).uint32Value, bounds: nil)
            let expected = row["events"] as! [[String: Any]]
            var matched = events.count == expected.count
            for (event, e) in zip(events, expected) {
                let p = e["point"] as! [Double]
                let expectedType = e["type"] as! Int
                let nativeType: UInt32 = expectedType == 25 ? 25 : expectedType == 26 ? 26 : expectedType == 27 ? 27 : UInt32(expectedType)
                matched = matched && event.type.rawValue == nativeType && event.location == CGPoint(x: p[0], y: p[1])
                    && event.flags.rawValue == (e["flags"] as! NSNumber).uint64Value
                    && event.getIntegerValueField(.mouseEventButtonNumber) == (e["button"] as! NSNumber).int64Value
                    && event.getIntegerValueField(.mouseEventClickState) == (e["click_state"] as! NSNumber).int64Value
                    && event.getIntegerValueField(.mouseEventNumber) == (e["number"] as! NSNumber).int64Value
                    && event.getIntegerValueField(.mouseEventSubtype) == 3
                    && event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == (e["window_91"] as! NSNumber).int64Value
                    && event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == (e["window_92"] as! NSNumber).int64Value
                compared += 1
            }
            check("real unposted NSEvent/CGEvent fields match the golden constructor-provider corpus \(row["name"]!)", matched)
        }
        check("retained corpus compares sixty constructed events without posting", compared == 60 && sequence.next() == 24)
        var locals: [CGPoint] = []
        let localFactory = ControllerNativeCoordinateEvents(setWindowLocation: { _, point in locals.append(point) })
        _ = try localFactory.click(at: .init(x: 20, y: 30), destination: .init(x: 40, y: 50), button: 0, count: 1, flags: 0, windowID: 77, bounds: .init(x: 10, y: 20, width: 200, height: 100), flipped: true)
        check("window-local flipped positions cover origin, midpoint and final release", locals == [.init(x: 10, y: 90), .init(x: 10, y: 90), .init(x: 20, y: 80), .init(x: 30, y: 70), .init(x: 30, y: 70)])
        var constructorCounts: [Int] = []
        let movementNumbers = SynthesizedEventNumberSequence(initialValue: 70)
        var movementFactory = ControllerNativeCoordinateEvents(numbers: movementNumbers, setWindowLocation: { _, _ in })
        let nativeConstructor = movementFactory.construct
        movementFactory.construct = { type, point, window, number, count in constructorCounts.append(count); return nativeConstructor(type, point, window, number, count) }
        let movement = try movementFactory.movement(at: .init(x: -20, y: 45), windowID: 77, bounds: nil)
        check("movement uses NSEvent clickCount=1 and shared number consumption", constructorCounts == [1] && movement[0].type == .mouseMoved && movement[0].flags.rawValue == 0 && movement[0].getIntegerValueField(.mouseEventNumber) == 70 && movementNumbers.next() == 71)
        for failedCall in [1, 2, 4, 5] {
            let counter = SynthesizedEventNumberSequence(); var calls = 0, failed = false
            var f = ControllerNativeCoordinateEvents(numbers: counter, setWindowLocation: { _, _ in })
            let native = f.construct
            f.construct = { type, point, window, number, count in calls += 1; return calls == failedCall ? nil : native(type, point, window, number, count) }
            do { _ = try f.click(at: .zero, destination: .init(x: 1, y: 2), button: 0, count: 1, flags: 0, windowID: nil, bounds: nil) } catch ControllerLowerClickFailure.cannotCreateEvent { failed = true }
            check("constructor failure \(failedCall) consumes only numbers reached before failure", failed && calls == failedCall && counter.next() == (failedCall == 1 ? 1 : 2))
        }
        let invalid = SynthesizedEventNumberSequence(); var failed = false
        do { _ = try ControllerNativeCoordinateEvents(numbers: invalid, setWindowLocation: { _, _ in }).click(at: .zero, destination: nil, button: 0, count: 0, flags: 0, windowID: nil, bounds: nil) } catch ControllerLowerClickFailure.invalidCount { failed = true }
        check("invalid native count fails before consuming any event number", failed && invalid.next() == 0)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "golden_constructor_provider_events": compared,
            "actual_native_NSEvent_CGEvent_objects": true,
            "actual_mouse_keyboard_focus_capture_preferences_or_clipboard": false,
            "ordinary_request_routing_accepted": false, "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native coordinate actions: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
