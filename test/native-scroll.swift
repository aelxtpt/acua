import Foundation
import CoreGraphics

@main enum NativeScrollTests {
    static func main() throws {
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var rows = [[String: Any]]()
        func check(_ value: Bool, _ name: String, comparedWithExpected: Bool = false) {
            rows.append(["name": name, "passed": value, "comparedWithExpected": comparedWithExpected])
            print("\(value ? "PASS" : "FAIL") scroll \(name)")
        }
        for (index, row) in (golden["math"] as! [[String: Any]]).enumerated() {
            let direction = NativeScroll.Direction(rawValue: (row["direction"] as! NSNumber).uint8Value)!
            let actual = try NativeScroll.delta(direction: direction, pages: (row["pages"] as! NSNumber).doubleValue,
                                                 extent: (row["extent"] as! NSNumber).doubleValue)
            let expected = (row["delta"] as! [NSNumber]).map(\.int64Value)
            check([actual.x, actual.y] == expected, "expected distance \(index)", comparedWithExpected: true)
        }
        for pages in [0.0, -0.0, -1, -.infinity, .nan] {
            do { try NativeScroll.validate(pages: pages); check(false, "nonpositive pages rejects") }
            catch let error as ServiceError {
                let expectedError = (golden["errors"] as! [[String: Any]]).first { ($0["tag"] as! NSNumber).intValue == 1 }!
                check(error.code == .unknownError && error.message == expectedError["message"] as! String,
                      "invalid pages \(pages) uses the expected error", comparedWithExpected: true)
            }
        }
        for size in [CGSize.zero, CGSize(width: -10, height: -20), CGSize(width: CGFloat.nan, height: CGFloat.nan), CGSize(width: 99, height: 99)] {
            let delta = try NativeScroll.delta(direction: .down, pages: 0.005, size: size)
            check(delta.x == 0 && delta.y == -1, "minimum hundred-point extent and away-from-zero half rounding")
        }
        let visible = CGSize(width: 913.125, height: 321.5)
        let x = try NativeScroll.delta(direction: .left, pages: 1.25, size: visible)
        let y = try NativeScroll.delta(direction: .down, pages: 1.25, size: visible)
        check(x.x == -1141 && y.y == -402, "horizontal and vertical extents selected independently")
        for (name, pages, extent) in [("positive-infinity", Double.infinity, 100.0), ("product-overflow", Double.greatestFiniteMagnitude, 100),
                                     ("Int64-overflow", Double(Int64.max), 1), ("negation-overflow", Double(Int64.min), 1)] {
            do { _ = try NativeScroll.delta(direction: .down, pages: pages, extent: extent); check(false, "robustness \(name)") }
            catch { check(true, "robustness controlled rejection \(name), no expected-value credit") }
        }
        for row in golden["wheel"] as! [[String: Any]] {
            let name = row["name"] as! String
            let window = (row["window"] as! NSNumber).uint32Value
            let expectedPoint = (row["point"] as! [NSNumber]).map(\.doubleValue)
            let event = try ScrollEventFactory.event(at: CGPoint(x: expectedPoint[0], y: expectedPoint[1]),
                deltaX: (row["dx"] as! NSNumber).int64Value, deltaY: (row["dy"] as! NSNumber).int64Value,
                windowID: window == 0 ? nil : window)
            // Modifier flags stay at the CoreGraphics default for the current
            // HID source, so they are compared with a fresh platform event.
            let source = CGEventSource(stateID: .hidSystemState)
            let platformEvent = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                wheel1: (row["dy"] as! NSNumber).int32Value, wheel2: (row["dx"] as! NSNumber).int32Value, wheel3: 0)
            let fields = row["fields"] as! [String: NSNumber]
            let equal = fields.allSatisfy { event.getIntegerValueField(CGEventField(rawValue: UInt32($0.key)!)!) == $0.value.int64Value }
            check(event.type.rawValue == (row["type"] as! NSNumber).uint32Value &&
                  event.location == CGPoint(x: expectedPoint[0], y: expectedPoint[1]) &&
                  event.flags == platformEvent?.flags && equal,
                  "unposted CoreGraphics event \(name)", comparedWithExpected: true)
        }
        for value in [Int64(Int32.max) + 1, Int64(Int32.min) - 1] {
            do { _ = try ScrollEventFactory.event(at: .zero, deltaX: value, deltaY: 0, windowID: nil); check(false, "event overflow") }
            catch { check(true, "event overflow rejects without native trap \(value)") }
        }
        let layout = ScreenshotGeometry.nativeLayout(frame: CGRect(x: -120.25, y: 30.75, width: 913.125, height: 321.5),
                                                    backingScale: 2, sizing: .points)!
        check(layout.visibleSize == visible, "retained visible extent preserves exact fractional window size")
        let passed = rows.filter { $0["passed"] as! Bool }.count
        let result: [String: Any] = ["passed": passed, "failed": rows.count - passed, "checks": rows,
            "expected_math_cases": 56, "expected_error_values": 2, "expected_unposted_event_cases": 6,
            "wheel_flags_compared_with_current_coregraphics_default": true,
            "native_input": false, "native_acceptance": false]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if passed != rows.count { exit(1) }
    }
}
