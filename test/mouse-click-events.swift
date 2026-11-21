import Foundation
import CoreGraphics

@main enum MouseClickEventTests {
    static func main() throws {
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        let buttons: [UInt32] = [0, 1, 2, 3, 5, 31, 255, 65535, UInt32.max]
        var inputs: [(String, CGPoint, UInt32, Int, UInt32, CGEventFlags)] = buttons.enumerated().map { index, button in
            ("button-\(button)", CGPoint(x: 212.75, y: 126.25), button, 1, index % 2 == 0 ? 0 : 26505,
             index % 3 == 0 ? [] : .maskShift)
        }
        inputs += [("button5-double", CGPoint(x: 14, y: 17), 5, 2, 0, []),
                   ("left-count101", CGPoint(x: 14, y: 17), 0, 101, 0, [])]
        precondition(reference.count == inputs.count)
        var number: Int64 = 0
        for (expected, input) in zip(reference, inputs) {
            let (name, point, button, count, window, flags) = input
            precondition(expected["name"] as? String == name)
            var events: [[String: Any]] = []
            for click in 1...count {
                let pair = try MouseClickEventFactory.events(at: point, button: button, clickCount: Int64(click),
                    flags: flags, windowID: window, eventNumber: number)
                number += 1
                for event in [pair.down, pair.up] {
                    events.append(["type": event.type.rawValue, "point": [event.location.x, event.location.y],
                        "flags": event.flags.rawValue, "click_state": event.getIntegerValueField(.mouseEventClickState),
                        "button": event.getIntegerValueField(.mouseEventButtonNumber),
                        "field_7": event.getIntegerValueField(.mouseEventSubtype),
                        "number": event.getIntegerValueField(.mouseEventNumber),
                        "window_91": event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
                        "window_92": event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)])
                }
            }
            precondition((events as NSArray).isEqual(expected["events"] as! NSArray), "Event mismatch: \(name)")
            print("PASS click events: \(name), \(events.count) events")
        }
    }
}
