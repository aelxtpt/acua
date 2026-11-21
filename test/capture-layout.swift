import Foundation
import CoreGraphics

@main enum CaptureLayoutTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); passed += 1; print("PASS \(name)") }
        func rejected(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(name) }
            catch is ServiceError { check(name, true) }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let frame = CGRect(x: -300, y: 150, width: 800, height: 500)
        let primary = CaptureLayout.Window(id: 1, frame: frame)
        let cursor = CaptureLayout.Window(id: 2, frame: CGRect(x: -330, y: 130, width: 80, height: 80))
        let unrelated = CaptureLayout.Window(id: 3, frame: CGRect(x: -1000, y: -1000, width: 3000, height: 2000))
        let displays = [CaptureLayout.Display(id: 10, frame: CGRect(x: -1000, y: 0, width: 1000, height: 800)),
                        CaptureLayout.Display(id: 20, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))]
        let single = try CaptureLayout.make(primaryID: 1, additionalIDs: [], windows: [primary, cursor, unrelated], displays: [])
        check("single-window capture does not depend on display enumeration", single.displayID == nil && single.sourceRect == nil)
        check("unrelated windows never enter a single-window filter", single.windowIDs == [1])
        let group = try CaptureLayout.make(primaryID: 1, additionalIDs: [2], windows: [unrelated, cursor, primary], displays: displays)
        check("primary stays first regardless of shareable-window order", group.windowIDs == [1, 2])
        check("largest screen intersection selects display", group.displayID == 20)
        check("cursor outside the primary never expands screenshot frame", group.screenFrame == frame)
        check("display source rectangle preserves negative crop origin", group.sourceRect == frame)
        let leftFrame = CGRect(x: -850, y: 210, width: 400, height: 300)
        let left = try CaptureLayout.make(primaryID: 4, additionalIDs: [2], windows: [.init(id: 4, frame: leftFrame), cursor], displays: displays)
        check("negative display origin is subtracted in points", left.displayID == 10 && left.sourceRect == CGRect(x: 150, y: 210, width: 400, height: 300))
        let above = try CaptureLayout.make(primaryID: 4, additionalIDs: [2], windows: [.init(id: 4, frame: CGRect(x: -700, y: -700, width: 400, height: 300)), cursor], displays: [.init(id: 30, frame: CGRect(x: -1000, y: -900, width: 1000, height: 900))])
        check("display above the main display keeps y-down crop coordinates", above.sourceRect == CGRect(x: 300, y: 200, width: 400, height: 300))
        let missing = try CaptureLayout.make(primaryID: 1, additionalIDs: [99], windows: [primary, unrelated], displays: displays)
        check("a disappeared optional window is omitted without including others", missing.windowIDs == [1])
        check("missing optional window retains requested display-crop path", missing.displayID == 20)
        let repeated = try CaptureLayout.make(primaryID: 1, additionalIDs: [1, 2, 2, 0, 3], windows: [primary, cursor, unrelated], displays: displays)
        check("duplicates and null window ID do not duplicate captured layers", repeated.windowIDs == [1, 2, 3])
        let tie = try CaptureLayout.make(primaryID: 5, additionalIDs: [2], windows: [.init(id: 5, frame: CGRect(x: -100, y: 100, width: 200, height: 200)), cursor], displays: displays)
        check("equal display overlap preserves the first display", tie.displayID == 10)
        let frames = displays.map(\.frame)
        check("scale selection and crop use the greatest overlap in the supplied coordinate space",
              CaptureLayout.bestDisplayIndex(for: frame, displayFrames: frames) == 1)
        let beyond = frame.offsetBy(dx: 3000, dy: 3000)
        check("off-display frames retain the first screen and an empty list has no match",
              CaptureLayout.bestDisplayIndex(for: beyond, displayFrames: frames) == 0 &&
              CaptureLayout.bestDisplayIndex(for: beyond, displayFrames: []) == nil)
        let invalidCursor = CaptureLayout.Window(id: 6, frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
        let compacted = try CaptureLayout.make(primaryID: 1, additionalIDs: [6], windows: [primary, invalidCursor], displays: displays)
        check("invalid optional frame is omitted", compacted.windowIDs == [1])
        rejected("missing primary cannot choose a decoy") { _ = try CaptureLayout.make(primaryID: 7, additionalIDs: [], windows: [unrelated], displays: displays) }
        rejected("zero primary ID is not a window") { _ = try CaptureLayout.make(primaryID: 0, additionalIDs: [], windows: [.init(id: 0, frame: frame)], displays: displays) }
        rejected("duplicate window IDs fail instead of dictionary trap or arbitrary choice") { _ = try CaptureLayout.make(primaryID: 1, additionalIDs: [], windows: [primary, primary], displays: displays) }
        rejected("multiple-window capture fails if display is unavailable") { _ = try CaptureLayout.make(primaryID: 1, additionalIDs: [2], windows: [primary, cursor], displays: []) }
        for invalid in [CGRect.zero, CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1), CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1)] {
            rejected("invalid or overflowing primary frame is rejected") { _ = try CaptureLayout.make(primaryID: 1, additionalIDs: [], windows: [.init(id: 1, frame: invalid)], displays: displays) }
        }
        let geometry = ScreenshotGeometry(windowID: 1, ownerPID: 123, screenFrame: group.screenFrame, pixelWidth: 1600, pixelHeight: 1000, includedWindowIDs: group.windowIDs)
        check("multi-window Retina center still maps to primary-window global point", try geometry.screenPoint(from: CGPoint(x: 800, y: 500)) == CGPoint(x: 100, y: 400))
        check("extra windows cannot change pointer routing window or origin", geometry.pointerTarget.windowID == 1 && geometry.pointerTarget.screenFrame == frame)

        func candidate(_ id: UInt32, pid: Int32 = 123, bounds: CGRect? = nil,
                       title: String? = nil, layer: Int = 0) -> CaptureLayout.NativeWindow {
            .init(id: id, ownerPID: pid, frame: bounds ?? frame, title: title, layer: layer)
        }
        func match(_ windows: [CaptureLayout.NativeWindow], title: String? = "Target", pid: Int32 = 123) -> UInt32? {
            CaptureLayout.matchNativeWindow(pid: pid, frame: frame, title: title, windows: windows,
                                            servicePID: 456, menuLevel: 24)?.id
        }
        check("native fallback keeps a unique exact PID and frame match even when its title differs",
              match([candidate(2, title: "Other"), candidate(3, pid: 999, title: "Target")]) == 2)
        check("native fallback requires exact geometry", match([candidate(2, bounds: frame.offsetBy(dx: 0.5, dy: 0))]) == nil)
        check("native fallback narrows equal frames by title and preserves front-to-back order",
              match([candidate(2), candidate(8, title: "Target"), candidate(3, title: "Target")]) == 8)
        check("native fallback requires a concrete matching title among equal frames",
              match([candidate(2), candidate(3)], title: nil) == nil && match([candidate(2), candidate(3)]) == nil)
        check("native fallback excludes menu-level windows and the service's own windows",
              match([candidate(2, layer: 24), candidate(3, pid: 456)]) == nil && match([candidate(3, pid: 456)], pid: 456) == nil)
        check("native fallback ignores a null window identifier", match([candidate(0)]) == nil)
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let desktopCandidates = [candidate(10, pid: 999, layer: desktopIconLevel),
                                 candidate(11, layer: desktopIconLevel - 1),
                                 candidate(12, layer: 0),
                                 candidate(0, layer: desktopIconLevel),
                                 candidate(13, bounds: .zero, layer: desktopIconLevel),
                                 candidate(14, layer: desktopIconLevel),
                                 candidate(15, layer: desktopIconLevel)]
        check("Finder desktop resolves the first valid icon-layer window owned by Finder",
              CaptureLayout.finderDesktopWindow(pid: 123, desktopIconLevel: desktopIconLevel, windows: desktopCandidates)?.id == 14)
        check("Finder desktop lookup cannot select another owner's icons or an ordinary Finder window",
              CaptureLayout.finderDesktopWindow(pid: 123, desktopIconLevel: desktopIconLevel,
                                                windows: Array(desktopCandidates.prefix(3))) == nil)
        check("native enumeration uses the onscreen list when every requested window is present",
              !CaptureLayout.needsFullWindowList(requestedIDs: [1, 2], onscreenIDs: [1, 2, 3]) &&
              !CaptureLayout.needsFullWindowList(requestedIDs: [], onscreenIDs: []))
        check("a missing primary or secondary ID requires full window enumeration",
              CaptureLayout.needsFullWindowList(requestedIDs: [1, 2], onscreenIDs: [2]) &&
              CaptureLayout.needsFullWindowList(requestedIDs: [1, 2], onscreenIDs: [1]))
        let offscreen = try CaptureLayout.make(primaryID: 1, additionalIDs: [2, 99], windows: [cursor, primary], displays: [],
                                               useDisplayForAdditionalWindows: false)
        check("offscreen capture preserves the selected crop and available IDs without requiring a display",
              offscreen.windowIDs == [1, 2] && offscreen.screenFrame == frame && offscreen.displayID == nil && offscreen.sourceRect == nil)
        rejected("full enumeration cannot replace a missing offscreen primary with another window") {
            _ = try CaptureLayout.make(primaryID: 99, additionalIDs: [2], windows: [cursor, primary], displays: [],
                                       useDisplayForAdditionalWindows: false)
        }
        print("\(passed) capture layout checks passed (geometry/selection; native pixels remain separate)")
    }
}
