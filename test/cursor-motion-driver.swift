import Foundation
enum CATransaction { static func begin() {}; static func commit() {}; static func setDisableActions(_ disabled: Bool) {} }
import CoreGraphics

typealias CGWindowID = UInt32
func CACurrentMediaTime() -> Double { ProcessInfo.processInfo.systemUptime }
final class NSWorkspace {
    static let shared = NSWorkspace()
    var accessibilityDisplayShouldReduceMotion = false
}
final class OwnedWindow {
    var alphaValue = 0.0
    var isVisible = false
    func orderFrontRegardless() { isVisible = true }
    func orderOut(_ sender: Any?) { isVisible = false }
}
final class CASpringAnimation {
    var fromValue = 0.0, toValue = 0.0, duration = 0.0, damping = 0.0, initialVelocity = 0.0
    var autoreverses = false
    init(keyPath: String) {}
}
final class OwnedLayer {
    var opacity: Float = 1
    var scale = 1.0
    func setValue(_ value: Double, forKeyPath: String) { scale = value }
    var animations = [CASpringAnimation]()
    func add(_ animation: CASpringAnimation, forKey: String) { animations.append(animation) }
    func removeAnimation(forKey: String) {}
}
final class CursorOverlay {
    private let startHandle: CGFloat = 0.35, endpointHandle: CGFloat = 0.35, arcSize: CGFloat = 0.06
    private let straightPathDistanceThreshold: CGFloat = 40
    private let springResponse = 0.28, springDamping = 1.0
    private var window: OwnedWindow? = OwnedWindow()
    private var motionLayer: OwnedLayer? = OwnedLayer(), labelLayer: OwnedLayer? = OwnedLayer(), pressLayer: OwnedLayer? = OwnedLayer()
    private let motionCompletion = CursorMotionCompletion()
    private var timer: Timer?, idleTimer: Timer?
    private var arcFlow: CGFloat = 1
    private var pressScale = 1.0
    private var visible = false
    private var targetWindowID: CGWindowID?
    private var lastReportedPosition: CGPoint?
    var locationObserver: ((CGPoint?, CGWindowID?, CGWindowID?) -> Void)?
    private var progress = 1.0, velocity = 0.0
    private var pathStart = CGPoint.zero, pathControl1 = CGPoint.zero, pathControl2 = CGPoint.zero, pathEnd = CGPoint.zero
    private var lastPoint = CGPoint.zero, prevPosition = CGPoint.zero
    var unavailable = false
    var samples = [CGPoint]()
    var point: CGPoint { lastPoint }
    var token: UUID? { motionCompletion.currentToken }
    var hasTimer: Bool { timer != nil }
    var shown: Bool { visible }
    var physicalPressScale: Double { pressLayer?.scale ?? -1 }
    var pressAnimations: [CASpringAnimation] { pressLayer?.animations ?? [] }
    func staleStep(_ token: UUID) { step(dt: 0.05, token: token) }
    private func ensureWindow() -> OwnedWindow? { unavailable ? nil : window }
    private func updateMotionGlow(moving: Bool, immediately: Bool = false) {}
    private func apply(position: CGPoint, velocity: CGFloat, moving: Bool = false) {
        guard window != nil else { return }
        samples.append(position); prevPosition = position; lastPoint = position
        if position != lastReportedPosition {
            lastReportedPosition = position
            locationObserver?(position, 1, targetWindowID)
        }
    }
    /* PRODUCTION_METHODS */
}

@main struct MotionDriverTests {
    static func main() throws {
        var rows = [[String: Any]]()
        func check(_ ok: Bool, _ name: String) {
            rows.append(["name": name, "passed": ok]); print("\(ok ? "PASS" : "FAIL") cursor motion \(name)")
        }
        func pump(until done: () -> Bool, seconds: Double = 2) {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 150, y: 190), c = CGPoint(x: 60, y: 80)
        let cursor = CursorOverlay()
        var calls = [Bool]()
        cursor.place(at: a) { calls.append($0) }
        check(calls == [true] && cursor.point == a && cursor.token == nil && !cursor.hasTimer, "first placement completes immediately")
        calls = []
        cursor.place(at: b) { calls.append($0) }
        check(calls.isEmpty && cursor.hasTimer && cursor.point == a, "animated placement waits")
        pump(until: { !calls.isEmpty })
        check(calls == [true] && cursor.point == b && !cursor.hasTimer && cursor.token == nil && cursor.samples.count > 2, "real spring timer completes at endpoint")
        var old = [Bool](), next = [Bool]()
        cursor.place(at: a) { old.append($0) }
        let stale = cursor.token!
        cursor.place(at: c) { next.append($0) }
        let before = cursor.point
        cursor.staleStep(stale)
        check(old == [false] && next.isEmpty && cursor.point == before && cursor.token != stale, "replacement cancels previous and stale step cannot advance replacement")
        pump(until: { !next.isEmpty })
        check(next == [true] && cursor.point == c, "replacement owns its completion")
        let early = CursorOverlay()
        early.place(at: a, animated: false)
        var earlyCalls = [Bool](), runningWhenReady = false, pointWhenReady = CGPoint.zero
        early.place(at: b, nextInteractionTiming: .closeEnough) {
            earlyCalls.append($0); runningWhenReady = early.hasTimer && early.token != nil; pointWhenReady = early.point
        }
        pump(until: { !earlyCalls.isEmpty })
        check(earlyCalls == [true] && runningWhenReady && hypot(pointWhenReady.x-b.x,pointWhenReady.y-b.y) <= 3.157,
              "early interaction releases within the release distance while real spring timer remains owned")
        pump(until: { early.token == nil })
        check(earlyCalls == [true] && early.point == b && !early.hasTimer, "early spring completes visually without a duplicate callback")
        early.hide()
        calls = []
        cursor.place(at: b) { calls.append($0) }; cursor.hide(); cursor.hide()
        check(calls == [false] && !cursor.shown && !cursor.hasTimer && cursor.token == nil, "hide completes pending movement once")
        cursor.place(at: a)
        calls = []
        cursor.place(at: b) { calls.append($0) }
        cursor.drag(from: a, to: c, duration: 0.06)
        check(calls == [false] && cursor.hasTimer && cursor.point == a, "drag replaces pending spring")
        pump(until: { cursor.token == nil })
        check(cursor.point == c && !cursor.hasTimer, "real drag timer ends and clears completion ownership")
        for duration in [0.0, -1, Double.nan, Double.infinity] {
            cursor.drag(from: a, to: b, duration: duration)
            check(cursor.point == b && cursor.token == nil && !cursor.hasTimer, "non-animated drag duration \(duration)")
        }
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = true
        calls = []; cursor.place(at: c) { calls.append($0) }
        check(calls == [true] && cursor.point == c && !cursor.hasTimer, "reduced motion completes immediately")
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = false
        cursor.unavailable = true
        calls = []; cursor.place(at: a) { calls.append($0) }
        check(calls == [false] && cursor.token == nil, "unavailable window completes without waiting")
        cursor.unavailable = false
        let nested = CursorOverlay()
        var nestedCalls = [Bool](), parentCalls = [Bool]()
        var fired = false
        nested.locationObserver = { point, _, _ in
            if point != nil && !fired {
                fired = true
                nested.place(at: c, animated: false) { nestedCalls.append($0) }
            }
        }
        nested.place(at: a) { parentCalls.append($0) }
        check(parentCalls == [false] && nestedCalls == [true] && nested.point == c && nested.token == nil, "reentrant location update owns its new placement")
        nested.locationObserver = nil
        nested.place(at: a, animated: false)
        fired = false; nestedCalls = []; parentCalls = []
        nested.locationObserver = { point, _, _ in
            if point == nil && !fired { fired = true; nested.place(at: c, animated: false) { nestedCalls.append($0) } }
        }
        nested.place(at: b) { parentCalls.append($0) }; nested.hide()
        check(parentCalls == [false] && nestedCalls == [true] && nested.shown && nested.point == c, "hide observer may create a new placement without losing it")
        nested.locationObserver = nil; nested.hide(); cursor.hide()
        check(!cursor.prepareInteraction() && !cursor.shown, "interaction preparation preserves a hidden cursor")
        check(!cursor.press(animationDuration: 0.05) && cursor.pressAnimations.isEmpty, "hidden cursor press skips animation and waiting")
        cursor.place(at: a, animated: false)
        check(cursor.prepareInteraction() && cursor.shown, "interaction preparation preserves a visible cursor")
        check(cursor.press() && cursor.pressAnimations.last?.duration == 0.12 && cursor.pressAnimations.last?.autoreverses == true, "ordinary press retains approved duration and autoreverse")
        check(cursor.press(animationDuration: 0.05) && cursor.pressAnimations.last?.duration == 0.05 && cursor.pressAnimations.last?.toValue == 0.94, "secondary press uses the requested duration and 0.94 compression")
        let animationCount = cursor.pressAnimations.count
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = true
        check(cursor.press(animationDuration: 0.05) && cursor.pressAnimations.count == animationCount, "reduced motion keeps visible press continuation without animation")
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = false
        cursor.unavailable = true
        check(!cursor.prepareInteraction(), "interaction preparation tolerates an unavailable window")
        check(!cursor.press() && cursor.pressAnimations.count == animationCount, "unavailable press window returns without animation")
        cursor.unavailable = false; cursor.hide()
        cursor.place(at: a, animated: false)
        cursor.setPressed(true)
        check(cursor.physicalPressScale == 0.94 && cursor.pressAnimations.last?.toValue == 0.94 && cursor.pressAnimations.last?.duration == 0.05 && cursor.pressAnimations.last?.autoreverses == false, "native mouse down holds compression without autoreverse")
        cursor.setPressed(false)
        check(cursor.physicalPressScale == 1 && cursor.pressAnimations.last?.fromValue == 0.94 && cursor.pressAnimations.last?.toValue == 1, "native mouse up restores cursor scale")
        let beforeReduced = cursor.pressAnimations.count
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = true
        cursor.setPressed(true); cursor.setPressed(false)
        check(cursor.physicalPressScale == 1 && cursor.pressAnimations.count == beforeReduced, "reduced motion updates held scale without animation")
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = false
        cursor.hide(); let beforeHidden = cursor.pressAnimations.count
        cursor.setPressed(true); cursor.setPressed(false)
        check(cursor.physicalPressScale == 1 && cursor.pressAnimations.count == beforeHidden, "hidden cursor does not animate physical press")
        cursor.place(at: a, animated: false); cursor.setPressed(true); cursor.hide()
        cursor.place(at: b, animated: false)
        check(cursor.physicalPressScale == 1, "hide during a held press restores scale before next placement")
        let passed = rows.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["passed": passed, "failed": rows.count - passed, "checks": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if passed != rows.count { exit(1) }
    }
}
