import Foundation
import CoreGraphics

@main enum CaptureTransitionTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1; print("PASS \(name)") }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0000001 }
        func target(_ edit: (inout JSON) -> Void = { _ in }) throws -> AppCaptureWire.AnimationTarget {
            var input: JSON = ["destinationFrame": ["x": 100.0, "y": 100.0, "width": 300.0, "height": 200.0],
                "agentDisplay": ["id": 1, "bounds": ["x": 0.0, "y": 0.0, "width": 1000.0, "height": 800.0],
                    "workArea": ["x": 0.0, "y": 25.0, "width": 1000.0, "height": 750.0], "scaleFactor": 2.0]]
            edit(&input)
            return try JSONDecoder().decode(AppCaptureWire.AnimationTarget.self, from: JSONSerialization.data(withJSONObject: input))
        }
        let screen = CaptureTransitionGeometry.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        let left = CaptureTransitionGeometry.Screen(id: 2, frame: CGRect(x: -800, y: 200, width: 800, height: 600), scale: 1)
        func destination(_ value: AppCaptureWire.AnimationTarget, _ screens: [CaptureTransitionGeometry.Screen] = [screen, left], _ main: UInt32? = 1) -> CaptureTransitionGeometry.Destination? {
            CaptureTransitionGeometry.destination(value, screens: screens, mainScreenID: main)
        }
        check("host top-left target maps into AppKit bottom-left coordinates", destination(try target())?.frame == CGRect(x: 100, y: 500, width: 300, height: 200))
        check("oversized target is capped and clamped to host work area", destination(try target { $0["destinationFrame"] = ["x": -50, "y": -100, "width": 2000, "height": 900] })?.frame == CGRect(x: 0, y: 25, width: 1000, height: 750))
        let onLeft = try target {
            $0["destinationFrame"] = ["x": -750, "y": 100, "width": 300, "height": 200]
            $0["agentDisplay"] = ["id": 2, "bounds": ["x": -800, "y": 0, "width": 800, "height": 600], "workArea": ["x": -800, "y": 0, "width": 800, "height": 600], "scaleFactor": 1]
        }
        check("negative-origin display mapping preserves screen offset", destination(onLeft)?.frame == CGRect(x: -750, y: 500, width: 300, height: 200))
        let idWins = try target { var display = $0["agentDisplay"] as! JSON; display["id"] = 2; $0["agentDisplay"] = display }
        check("valid display ID takes precedence over geometric overlap", destination(idWins)?.screen.id == 2)
        let unknownID = try target { var display = $0["agentDisplay"] as! JSON; display["id"] = -1; $0["agentDisplay"] = display }
        check("unknown display ID falls back to target overlap", destination(unknownID)?.screen.id == 1)
        let offscreen = try target { var display = $0["agentDisplay"] as! JSON; display["id"] = -1; $0["agentDisplay"] = display; $0["destinationFrame"] = ["x": 4000, "y": 4000, "width": 100, "height": 100] }
        check("missing target overlap falls back to supplied display bounds", destination(offscreen)?.screen.id == 1)
        let noOverlap = try target {
            $0["destinationFrame"] = ["x": 4000, "y": 4000, "width": 100, "height": 100]
            $0["agentDisplay"] = ["id": -1, "bounds": ["x": 4000, "y": 4000, "width": 800, "height": 600], "workArea": ["x": 4000, "y": 4000, "width": 800, "height": 600], "scaleFactor": 1]
        }
        check("both overlap fallbacks can fall back to main screen", destination(noOverlap, [screen, left], 2)?.screen.id == 2)
        check("no resolvable screen yields no transition", destination(noOverlap, [screen], nil) == nil)
        check("no displays yields no transition", destination(try target(), []) == nil)
        check("empty destination disables the optional transition", destination(try target { $0["destinationFrame"] = ["x": 1, "y": 1, "width": 0, "height": 100] }) == nil)
        check("invalid host scale disables the optional transition", destination(try target { var display = $0["agentDisplay"] as! JSON; display["scaleFactor"] = 0; $0["agentDisplay"] = display }) == nil)
        check("empty host work area disables the optional transition", destination(try target { var display = $0["agentDisplay"] as! JSON; display["workArea"] = ["x": 0, "y": 0, "width": 0, "height": 100]; $0["agentDisplay"] = display }) == nil)
        check("CG conversion keeps primary origin for vertical arrangements", CaptureTransitionGeometry.fromCG(CGRect(x: -100, y: -200, width: 50, height: 100), primary: screen.frame) == CGRect(x: -100, y: 900, width: 50, height: 100))
        check("nonfinite rectangles are rejected", !CaptureTransitionGeometry.valid(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
        check("trimmed window title is preferred", CaptureTransitionGeometry.title(window: "  Title\n", app: "App", style: .standard) == "Title")
        check("empty window title falls back to app name", CaptureTransitionGeometry.title(window: " \n", app: " App ", style: .standard) == "App")
        check("quick chat does not display a title", CaptureTransitionGeometry.title(window: "Title", app: "App", style: .quickChat) == nil)
        check("blank titles stay absent", CaptureTransitionGeometry.title(window: " ", app: nil, style: .standard) == nil)
        check("opening fade keeps its exact endpoints", CaptureTransitionGeometry.fade(0, easeInOut: true) == 0 && CaptureTransitionGeometry.fade(1, easeInOut: true) == 1)
        check("opening fade is symmetric at its midpoint", near(CaptureTransitionGeometry.fade(0.5, easeInOut: true), 0.5))
        check("accessory ease-in follows its cubic curve rather than linear opacity", abs(CaptureTransitionGeometry.fade(0.5) - 0.3153568125) < 0.000001)
        let a = CGRect(x: 0, y: 0, width: 600, height: 400), b = CGRect(x: 100, y: 100, width: 300, height: 200)
        let same = CaptureTransitionGeometry.metrics(source: b, destination: b, style: .standard, hasTitle: true, fontHeight: 15.1, scale: 2)!
        check("zero-distance spring has the fixed response and duration", near(same.springResponse, 0.28) && near(same.animationDuration, 0.99) && same.dampingFraction == 0.73)
        check("title height rounds at backing scale before outer ceil", same.snapshotHeight == 220)
        let farther = CaptureTransitionGeometry.metrics(source: a.offsetBy(dx: 10000, dy: 0), destination: b, style: .quickChat, hasTitle: true, fontHeight: 15.1, scale: 2)!
        check("distance increases the spring response below its asymptote", farther.springResponse > same.springResponse && farther.springResponse < 0.57)
        check("quick chat snapshot height excludes title", farther.snapshotHeight == 200)
        check("absent standard title adds no reserved text height", CaptureTransitionGeometry.metrics(source: a, destination: b, style: .standard, hasTitle: false, fontHeight: 15, scale: 2)?.snapshotHeight == 200)
        check("corner radius caps at half the smaller extent", CaptureTransitionGeometry.cornerRadius(1000, frame: b) == 100)
        check("missing/nonfinite corner radius is zero", CaptureTransitionGeometry.cornerRadius(nil, frame: b) == 0 && CaptureTransitionGeometry.cornerRadius(.infinity, frame: b) == 0)
        check("negative radius is passed through unclamped", CaptureTransitionGeometry.cornerRadius(-3, frame: b) == -3)
        check("aspect fit is centered without distortion", CaptureTransitionGeometry.aspectFit(CGSize(width: 600, height: 300), in: CGRect(x: 0, y: 0, width: 300, height: 300)) == CGRect(x: 0, y: 75, width: 300, height: 150))
        let inset = CaptureTransitionGeometry.insets(size: CGSize(width: 300, height: 200), progress: 1, shadow: .init())
        check("default final shadow inset is 10 top and 20 on the sides", inset == .init(top: 10, left: 20, bottom: 0, right: 20))
        check("small targets retain at least one point of content", CaptureTransitionGeometry.insets(size: CGSize(width: 2, height: 2), progress: 1, shadow: .init()) == .init(top: 1, left: 0, bottom: 0, right: 0))
        func layout(_ p: CGFloat, _ style: AppCaptureWire.PresentationStyle = .standard) -> CaptureTransitionGeometry.Layout? {
            CaptureTransitionGeometry.layout(source: a, destination: b, imageSize: a.size, progress: p,
                initialCornerRadius: 9, targetCornerRadius: 12, style: style, hasTitle: true, fontHeight: 15.1, scale: 2)
        }
        check("movement begins at the full source rectangle", layout(0)?.container == a)
        check("movement ends at the resolved destination", layout(1)?.container == b)
        check("midpoint follows the curved center path", near(layout(0.5)!.container.midX, 275) && near(layout(0.5)!.container.midY, 150))
        check("scale bump applies during the move", layout(0.5)!.container.width > 450)
        check("spring overshoot is retained rather than clipped", layout(1.02)!.container.midX < b.midX)
        check("invalid progress produces no geometry", layout(.nan) == nil)
        check("standard accessory icon is 24 points", layout(1)!.icon.size == CGSize(width: 24, height: 24))
        check("quick chat accessory icon is 16 points", layout(1, .quickChat)!.icon.size == CGSize(width: 16, height: 16))
        check("quick chat removes title and shadow", layout(1, .quickChat)!.title == nil && layout(1, .quickChat)!.shadowOpacity == 0)
        check("standard final title is pixel snapped below the target", layout(1)!.title == CGRect(x: 110, y: 80.5, width: 280, height: 15.5))
        check("late standard fade leaves the expected mask endpoints", layout(1)!.maskAlphas == [1, 1, 0.20999999999999996, 0, 0, 0])
        check("image corner approaches the two-point final corner", layout(1)!.imageCornerRadius == 2)
        let locations = CaptureTransitionGeometry.maskLocations(image: CGRect(x: 0, y: 30, width: 20, height: 60), mask: CGRect(x: 0, y: 0, width: 20, height: 100))
        check("gradient stops are based on the actual image span", near(locations[1], 0.1) && near(locations[2], 0.595) && near(locations[4], 0.7))
        var lifecycle = CaptureTransitionLifecycle()
        check("complete before opening only records intent", lifecycle.send(.complete).isEmpty && lifecycle.completionRequested)
        check("start requests opening once", lifecycle.send(.start) == [.open] && lifecycle.send(.start).isEmpty)
        check("opening completion starts the move", lifecycle.send(.openingFinished) == [.move])
        check("early completion waits for move before cleanup", lifecycle.send(.moveFinished) == [.wakeMoveWaiters, .close] && lifecycle.phase == .cancelled)
        check("terminal transitions ignore late events", lifecycle.send(.start).isEmpty && lifecycle.send(.cancel).isEmpty)
        lifecycle = CaptureTransitionLifecycle(); _ = lifecycle.send(.start); _ = lifecycle.send(.openingFinished)
        check("arrival wakes waiters while retaining overlay", lifecycle.send(.moveFinished) == [.wakeMoveWaiters] && lifecycle.phase == .arrived)
        check("consumer completion then closes the arrived overlay", lifecycle.send(.complete) == [.wakeMoveWaiters, .close])
        lifecycle = CaptureTransitionLifecycle(); _ = lifecycle.send(.start)
        check("cancellation wakes waiters during opening", lifecycle.send(.cancel) == [.wakeMoveWaiters, .close])
        print("\(count) transition geometry/lifecycle checks passed; native overlay and protocol completion are separate checks")
    }
}
