import Foundation
import CoreGraphics

@main enum WindowTargetTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); passed += 1; print("PASS \(name)") }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) }
            catch is ServiceError { check(name, true) }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let parent = MouseTargeting.Window(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        let child = MouseTargeting.Window(id: 2, pid: 100, frame: CGRect(x: 200, y: 180, width: 140, height: 120))
        let overlay = MouseTargeting.Window(id: 3, pid: 100, frame: CGRect(x: 220, y: 190, width: 50, height: 50))
        let point = CGPoint(x: 240, y: 210)
        func choose(_ ids: [UInt32], _ windows: [MouseTargeting.Window] = [parent, child], _ location: CGPoint = CGPoint(x: 240, y: 210)) throws -> MouseTargeting.Window {
            try MouseTargeting.select(at: location, orderedIDs: ids, windows: windows)
        }
        check("foreground child receives a point overlapping its parent", try choose([2, 1]).id == 2)
        check("window server order overrides AX enumeration order", try choose([2, 1], [child, parent]).id == 2)
        check("raised parent takes precedence when its own window is first", try choose([1, 2]).id == 1)
        check("point outside child continues to the parent", try choose([2, 1], [parent, child], CGPoint(x: 500, y: 400)).id == 1)
        check("nested panel uses the highest containing window", try choose([3, 2, 1], [parent, child, overlay]).id == 3)
        check("unmanaged desktop windows do not enter the app's candidate set", try choose([999, 2, 1]).id == 2)
        check("duplicate ordering entries do not change the target", try choose([2, 2, 1]).id == 2)
        check("AX aliases for exactly the same window are accepted", try choose([2, 1], [parent, child, child]).id == 2)
        rejects("conflicting identities are rejected before any pointer event") { _ = try choose([2, 1], [parent, child, .init(id: 2, pid: 100, frame: child.frame.offsetBy(dx: 1, dy: 0))]) }
        rejects("PID conflict cannot redirect a known window") { _ = try choose([2, 1], [parent, child, .init(id: 2, pid: 777, frame: child.frame)]) }
        rejects("missing server order does not fall back to a focused window") { _ = try choose([]) }
        rejects("a hidden AX window cannot become an onscreen target") { _ = try choose([1], [child]) }
        rejects("point outside every managed window is rejected") { _ = try choose([2, 1], [parent, child], CGPoint(x: 900, y: 900)) }
        for point in [CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 1, y: CGFloat.infinity)] {
            rejects("nonfinite pointer position is rejected") { _ = try choose([2, 1], [parent, child], point) }
        }
        let invalid = [MouseTargeting.Window(id: 0, pid: 100, frame: parent.frame), .init(id: 9, pid: 0, frame: parent.frame), .init(id: 10, pid: 100, frame: .zero)]
        check("invalid candidates cannot displace an actual app window", try choose([0, 9, 10, 1], invalid + [parent]).id == 1)
        let remote = MouseTargeting.Window(id: 44, pid: 200, frame: child.frame)
        let target = try choose([44, 1], [parent, remote]).pointer
        check("hosted AX window retains its actual event PID", target.ownerPID == 200 && target.windowID == 44)
        check("window-local coordinates use selected child bounds", target.screenFrame == child.frame && point.x - target.screenFrame.minX == 40 && point.y - target.screenFrame.minY == 30)
        let image = ScreenshotGeometry(windowID: 1, ownerPID: 100, screenFrame: parent.frame, pixelWidth: 1000, pixelHeight: 800)
        let pixelPoint = try image.screenPoint(from: CGPoint(x: 280, y: 220))
        let pixelTarget = try choose([2, 1], [parent, child], pixelPoint)
        check("Retina pixels stay anchored to parent crop before choosing the child", pixelPoint == point && pixelTarget.id == 2)
        let negative = MouseTargeting.Window(id: 5, pid: 100, frame: CGRect(x: -900, y: -500, width: 200, height: 100))
        check("negative display coordinates can select a child window", try choose([5, 1], [parent, negative], CGPoint(x: -800, y: -450)).id == 5)

        check("ordinary host app needs no remote process", MouseTargeting.remotePID(hostPID: 100, ancestry: [(100, .application)]) == nil)
        check("finished view service is remote", MouseTargeting.remotePID(hostPID: 100, ancestry: [(200, .service), (100, .application)]) == 200)
        check("unknown or unfinished process continues up ancestry", MouseTargeting.remotePID(hostPID: 100, ancestry: [(300, .unavailable), (200, .service)]) == 200)
        check("regular external app is not classified as a hosted view service", MouseTargeting.remotePID(hostPID: 100, ancestry: [(200, .application), (201, .service)]) == nil)
        check("host PID itself cannot become remote even if prohibited", MouseTargeting.remotePID(hostPID: 100, ancestry: [(100, .service), (200, .service)]) == nil)
        check("missing process ancestry cannot guess a PID", MouseTargeting.remotePID(hostPID: 100, ancestry: []) == nil)
        check("invalid PID is ignored while finding a valid service", MouseTargeting.remotePID(hostPID: 100, ancestry: [(0, .service), (200, .service)]) == 200)

        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1280, y: -200, width: 1280, height: 1024)
        let above = CGRect(x: 200, y: 900, width: 1000, height: 800)
        let below = CGRect(x: 100, y: -800, width: 1100, height: 800)
        func appKit(_ p: CGPoint, _ frames: [CGRect] = []) -> CGPoint? {
            MouseTargeting.appKitPoint(from: p, screenFrames: frames.isEmpty ? [primary, left, above, below] : frames)
        }
        check("primary hit conversion uses points without Retina scaling", appKit(point) == CGPoint(x: 240, y: 690))
        check("top edge of primary display participates in hit testing", appKit(.zero) == CGPoint(x: 0, y: 900))
        check("left display keeps global origin despite its different height", appKit(CGPoint(x: -600, y: 300)) == CGPoint(x: -600, y: 600))
        check("display above primary uses negative CG y", appKit(CGPoint(x: 400, y: -400)) == CGPoint(x: 400, y: 1300))
        check("display below primary keeps global y", appKit(CGPoint(x: 400, y: 1200)) == CGPoint(x: 400, y: -300))
        check("gap between displays is not a mouse hit", appKit(CGPoint(x: 1300, y: -100)) == nil)
        check("missing displays cannot guess an AppKit origin", MouseTargeting.appKitPoint(from: point, screenFrames: []) == nil)
        check("invalid primary cannot supply a coordinate origin", appKit(point, [.zero, primary]) == nil)
        check("nonfinite coordinate does not reach native hit test", appKit(CGPoint(x: CGFloat.infinity, y: 1)) == nil)
        check("right display edge is excluded", appKit(CGPoint(x: 1440, y: 300)) == nil)
        check("bottom display edge is excluded", appKit(CGPoint(x: 400, y: 1700)) == nil)

        var hitCalls = 0, resolveCalls = 0
        func refine(_ front: UInt32?, selected: UInt32 = 1, hit: Int? = 7) throws -> MouseTargeting.Window {
            try MouseTargeting.refine(provisional: parent, selectedWindowID: selected, frontWindowID: front,
                hitTest: { hitCalls += 1; return hit },
                resolve: { _ in resolveCalls += 1; return remote })
        }
        check("another app's top window keeps the scoped result", try refine(999) == parent)
        check("a blocked SystemWide lookup never runs", hitCalls == 0 && resolveCalls == 0)
        check("missing top window keeps the scoped result", try refine(nil) == parent)
        check("invalid matching zero IDs cannot enable global hit testing", try refine(0, selected: 0) == parent && hitCalls == 0)
        check("matching hit window can replace target with actual hosted PID", try refine(1) == remote && hitCalls == 1 && resolveCalls == 1)
        check("missing global element preserves the provisional target", try refine(1, hit: nil) == parent && hitCalls == 2 && resolveCalls == 1)
        rejects("global AX errors do not silently use a stale provisional target") {
            let _: MouseTargeting.Window = try MouseTargeting.refine(provisional: parent, selectedWindowID: 1, frontWindowID: 1,
                hitTest: { () throws -> Int? in throw ServiceError(.accessibilityError, "Native hit failure") }, resolve: { _ in remote })
        }
        rejects("hit without host ancestry fails instead of redirecting to another app") {
            let _: MouseTargeting.Window = try MouseTargeting.refine(provisional: parent, selectedWindowID: 1, frontWindowID: 1,
                hitTest: { 7 }, resolve: { _ in throw ServiceError(.accessibilityError, "No host window") })
        }
        print("\(passed) window-target checks passed; real AX hit testing and event delivery remain native checks")
    }
}
