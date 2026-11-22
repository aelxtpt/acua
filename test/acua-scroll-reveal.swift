import CoreGraphics
import Foundation

// Unit tests for revealing an offscreen element by moving its scroll area's
// scroll bar, with a fake accessibility tree. No events are posted.

private final class ScrollWrites: @unchecked Sendable {
    var values: [CGFloat] = []
}

/// A scroll area (viewport y 103...263) with a vertical bar at the bottom
/// (value 1). `children` decides what AX exposes inside the area: AppKit does
/// not expose a plain NSView document, only the controls placed in it.
private struct FakeTree: ControllerClickablePointBackend {
    typealias Node = String
    typealias Identity = String

    let frames: [String: CGRect]
    let areaChildren: [String]
    let writes: ScrollWrites

    func identity(_ node: String) -> String { node }
    func role(_ node: String) -> String {
        switch node {
        case "area": "AXScrollArea"
        case "bar": "AXScrollBar"
        case "document": "AXGroup"
        default: "AXButton"
        }
    }
    func title(_ node: String) -> String? { nil }
    func bundle(_ node: String) -> String? { nil }
    func frame(_ node: String) -> CGRect? { frames[node] }
    func frameAttribute(_ node: String, uncached: Bool) -> CGRect? { frames[node] }
    func parent(_ node: String, uncached: Bool) -> String? { node == "area" ? nil : "area" }
    func children(_ node: String) -> [String] { node == "area" ? areaChildren + ["bar"] : [] }
    func actions(_ node: String) -> [String] { [] }
    func supportedAndSettable(_ attribute: String, _ node: String) -> Bool { false }
    func settable(_ attribute: String, _ node: String) -> Bool { false }
    func performReveal(_ node: String) throws {}
    func setReveal(_ node: String) throws {}
    func setVisibleRect(_ rect: CGRect, _ node: String) throws {}
    func scrollBar(_ node: String, vertical: Bool) -> String? { vertical ? "bar" : nil }
    func enabled(_ node: String) -> Bool? { true }
    func scrollValue(_ node: String) -> CGFloat? { 1 }
    func setScrollValue(_ value: CGFloat, _ node: String) throws { writes.values.append(value) }
    func application(_ bundle: String) -> String? { nil }
    func hitTest(_ application: String, _ point: CGPoint) -> String? { nil }
    func same(_ left: String, _ right: String) -> Bool { left == right }
    func now() -> TimeInterval { 0 }
    func delay(_ seconds: TimeInterval) {}
}

@main
enum AcuaScrollRevealTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static let viewport = CGRect(x: 270, y: 103, width: 260, height: 160)
    private static let target = CGRect(x: 299, y: -373, width: 172, height: 37)

    static func main() throws {
        // Only the target button is exposed: the union of children (37 pt) is
        // smaller than the viewport, yet the button is 476 pt above it.
        let sparse = ScrollWrites()
        let sparseTree = FakeTree(frames: ["area": viewport, "button": target], areaChildren: ["button"], writes: sparse)
        let sparseScrolled = try ControllerClickablePoint(backend: sparseTree).scrollArea("area", target: target)
        check("ScrollArea_OnlyTargetExposed_ScrollsToTheTop",
              sparseScrolled && sparse.values == [0], "scrolled=\(sparseScrolled) writes=\(sparse.values)")

        // A document group spanning the full 750 pt content keeps the plain
        // arithmetic: centre the target in the viewport.
        let full = ScrollWrites()
        let fullTree = FakeTree(frames: ["area": viewport, "button": target,
                                         "document": CGRect(x: 270, y: -487, width: 260, height: 750)],
                                areaChildren: ["document", "button"], writes: full)
        let fullScrolled = try ControllerClickablePoint(backend: fullTree).scrollArea("area", target: target)
        let expected = CGFloat(52.5) / 590
        check("ScrollArea_FullDocumentExposed_CentresTheTarget",
              fullScrolled && full.values.count == 1 && abs(full.values[0] - expected) < 0.0001,
              "scrolled=\(fullScrolled) writes=\(full.values)")

        // A target already inside the viewport needs no scrolling.
        let visible = ScrollWrites()
        let inside = CGRect(x: 299, y: 150, width: 172, height: 37)
        let visibleTree = FakeTree(frames: ["area": viewport, "button": inside], areaChildren: ["button"], writes: visible)
        let visibleScrolled = try ControllerClickablePoint(backend: visibleTree).scrollArea("area", target: inside)
        check("ScrollArea_TargetAlreadyVisible_DoesNotScroll", !visibleScrolled && visible.values.isEmpty)

        print("\(passed) scroll reveal tests passed")
    }
}
