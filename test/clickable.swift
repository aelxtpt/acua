import Foundation
import CoreGraphics

@main enum ClickableTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1; print("PASS \(name)") }
        let button = CGRect(x: 30, y: 30, width: 40, height: 20), window = CGRect(x: 0, y: 0, width: 200, height: 120)
        check("visible control uses its actual center", ClickableGeometry.point(frame: button, clips: [window]) == CGPoint(x: 50, y: 40))
        check("center outside a scroll viewport is not clickable", ClickableGeometry.point(frame: button, clips: [window, CGRect(x: 0, y: 60, width: 200, height: 40)]) == nil)
        check("all nested clipping ancestors must contain the center", ClickableGeometry.point(frame: button, clips: [window, CGRect(x: 40, y: 35, width: 40, height: 20), CGRect(x: 55, y: 0, width: 50, height: 90)]) == nil)
        check("visible center remains usable for a partially clipped control", ClickableGeometry.point(frame: button, clips: [CGRect(x: 45, y: 35, width: 40, height: 40)]) == CGPoint(x: 50, y: 40))
        check("an edge sliver does not move the pointer to a different center", ClickableGeometry.point(frame: button, clips: [CGRect(x: 65, y: 30, width: 50, height: 30)]) == nil)
        check("empty frames are rejected", ClickableGeometry.point(frame: .zero, clips: [window]) == nil)
        check("infinite frames are rejected", ClickableGeometry.point(frame: .infinite, clips: [window]) == nil)
        check("non-finite origins are rejected", ClickableGeometry.point(frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), clips: [window]) == nil)
        check("non-finite clipping frames are rejected", ClickableGeometry.point(frame: button, clips: [.infinite]) == nil)
        check("no active display means no visible target", ClickableGeometry.point(frame: button, clips: [window], displays: []) == nil)
        check("off-display targets are rejected", ClickableGeometry.point(frame: button, clips: [window], displays: [CGRect(x: 400, y: 0, width: 100, height: 100)]) == nil)
        check("negative display origins retain global coordinates", ClickableGeometry.point(frame: CGRect(x: -1400, y: -200, width: 100, height: 40), clips: [CGRect(x: -1440, y: -300, width: 1440, height: 900)], displays: [CGRect(x: -1440, y: -300, width: 1440, height: 900)]) == CGPoint(x: -1350, y: -180))
        check("a gap between displays is not clickable", ClickableGeometry.point(frame: button, clips: [window], displays: [CGRect(x: -200, y: 0, width: 200, height: 200), CGRect(x: 100, y: 0, width: 200, height: 200)]) == nil)
        check("scroll areas clip descendants", ClickableGeometry.clips(role: "AXScrollArea", actions: []))
        check("ordinary groups do not clip descendants", !ClickableGeometry.clips(role: "AXGroup", actions: []))
        check("page-scrollable groups clip descendants", ClickableGeometry.clips(role: "AXGroup", actions: ["AXScrollDownByPage"]))
        check("reveal-only groups do not clip descendants", !ClickableGeometry.clips(role: "AXGroup", actions: ["AXScrollToVisible"]))
        check("other scroll prefixes do not make a clipping group", !ClickableGeometry.clips(role: "AXGroup", actions: ["AXScrollDown"]))
        for role in ["AXWindow", "AXSheet", "AXMenu", "AXPopover"] {
            check("\(role) is a clipping boundary", ClickableGeometry.clips(role: role, actions: []) && ClickableGeometry.boundary(role: role))
        }
        check("scroll area is not an ancestry boundary", !ClickableGeometry.boundary(role: "AXScrollArea"))
        func scroll(_ targetMin: CGFloat, _ targetMax: CGFloat, _ visibleMin: CGFloat = 0, _ visibleMax: CGFloat = 100,
                    _ contentMin: CGFloat = 0, _ contentMax: CGFloat = 500, _ value: CGFloat? = 0) -> CGFloat? {
            ClickableGeometry.scrollValue(targetMin: targetMin, targetMax: targetMax, visibleMin: visibleMin,
                visibleMax: visibleMax, contentMin: contentMin, contentMax: contentMax, value: value)
        }
        func near(_ actual: CGFloat?, _ expected: CGFloat) -> Bool { actual.map { abs($0 - expected) < 0.000001 } ?? false }
        check("scroll centers a smaller offscreen target", near(scroll(200, 240), 0.425))
        check("scroll retains an already visible target", scroll(20, 80) == nil)
        check("scroll aligns the leading edge of an oversized target", near(scroll(-30, 120, 0, 100, 0, 500, 0.5), 0.425))
        check("scroll aligns the trailing edge of an oversized target", near(scroll(20, 170), 0.175))
        check("scroll infers the current offset when the scrollbar value is unavailable", near(scroll(220, 240, 100, 200, 0, 500, nil), 0.45))
        check("scroll handles negative content origins", near(scroll(-60, -40, 0, 100, -400, 100, 1), 0.75))
        check("scroll clamps offsets below the document", scroll(-200, -180) == 0)
        check("scroll clamps offsets beyond the document", scroll(1000, 1020) == 1)
        check("scroll clamps out-of-range scrollbar values", near(scroll(200, 240, 0, 100, 0, 500, -1), 0.425))
        check("scroll rejects empty targets", scroll(20, 20) == nil)
        check("scroll rejects empty viewports", scroll(200, 240, 0, 0) == nil)
        check("scroll rejects non-scrollable content", scroll(200, 240, 0, 100, 0, 100) == nil)
        check("scroll rejects non-finite geometry", scroll(.nan, 240) == nil && scroll(200, .infinity) == nil)
        check("scroll rejects non-finite scrollbar values", scroll(200, 240, 0, 100, 0, 500, .nan) == nil)
        check("Chess matches only a lowercase file and rank at the end of a title",
              ["a1", "White pawn e2", "h8"].allSatisfy { ClickableGeometry.isChessSquareTitle($0) } &&
              [nil, "", "1", "A1", "e9", "i2", "e2 pawn", "e2 "].allSatisfy { !ClickableGeometry.isChessSquareTitle($0) })
        let board = CGRect(x: -128, y: 32, width: 128, height: 64)
        var queries: [CGPoint] = [], boardReads = 0
        func parent() -> CGRect? { boardReads += 1; return board }
        let center = CGPoint(x: button.midX, y: button.midY)
        let adjusted = ClickableGeometry.chessSquarePoint(frame: button, parentFrame: parent) { point in
            queries.append(point)
            if point == center { return false }
            if point == CGPoint(x: -127, y: 32.5) || point == CGPoint(x: -121, y: 36.5) { return true }
            return nil
        }
        check("Chess probes the center before visiting all 4,096 board cell centers", queries.count == 4097 &&
              queries.first == center && queries[1] == CGPoint(x: -127, y: 32.5) &&
              queries.last == CGPoint(x: -1, y: 95.5) && boardReads == 1)
        check("Chess averages matching samples in screen coordinates", adjusted == CGPoint(x: -124, y: 34.5))
        check("a correct Chess center keeps the ordinary geometry path",
              ClickableGeometry.chessSquarePoint(frame: button, parentFrame: parent, matches: { _ in true }) == nil && boardReads == 1)
        check("an unavailable center hit keeps the ordinary geometry path",
              ClickableGeometry.chessSquarePoint(frame: button, parentFrame: parent, matches: { _ in nil }) == nil && boardReads == 1)
        check("an unavailable or invalid board frame cannot produce a Chess point",
              ClickableGeometry.chessSquarePoint(frame: button, parentFrame: { nil }, matches: { _ in false }) == nil &&
              ClickableGeometry.chessSquarePoint(frame: button, parentFrame: { .zero }, matches: { _ in false }) == nil)
        check("no matching Chess sample keeps the ordinary geometry path",
              ClickableGeometry.chessSquarePoint(frame: button, parentFrame: parent, matches: { _ in false }) == nil)
        enum SampleError: Error { case cancelled }
        var sampled = 0
        do {
            _ = try ClickableGeometry.chessSquarePoint(frame: button, parentFrame: parent) { _ in
                sampled += 1
                if sampled == 9 { throw SampleError.cancelled }
                return false
            }
            preconditionFailure("Cancelled search returned normally")
        } catch SampleError.cancelled { check("Chess search can stop between hit tests", sampled == 9) }
        print("\(count) clickable geometry checks passed")
    }
}
