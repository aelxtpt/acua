import Foundation
import CoreGraphics
import ObjectiveC

final class OwnedElement { let id: Int; init(_ id: Int = 1) { self.id = id } }
typealias AXUIElement = OwnedElement
struct EventStreamNodeAction {}
struct PointerTarget { let windowID: UInt32 = 77 }
struct OwnedTarget { let element = OwnedElement(); let point = CGPoint(x: 10, y: 20); let pointer = PointerTarget() }
enum OwnedAXError: Int { case success = 0, failure = -1 }
let kAXPickAction = "AXPick", kAXPressAction = "AXPress"
let kAXRoleAttribute = "AXRole", kAXMenuBarItemRole = "AXMenuBarItem"

private struct Scenario {
    let name: String, expected: String
    var native = true, force = false, kind = "element", actions = ["AXPress"]
    var web = false, webThrows = false, menuSelected = false
    var menuAction: String? = nil
    var options: JSON = [:]
    var webReads = 1, preferenceReads = 1
    var scrolled = false, cursor = true, visible = true, noPoint = false
    var fault: String? = nil
    var cursorAfterMove: Bool? = nil, cursorAfterWeb: Bool? = nil
    var mouseCount = 1, mouseButton = 0
    var mouseDuration = 0.0, mouseHeld = false
    init(_ name: String, _ expected: String, native: Bool = true, force: Bool = false,
         kind: String = "element", actions: [String] = ["AXPress"], web: Bool = false,
         webThrows: Bool = false, menuSelected: Bool = false, menuAction: String? = nil,
         options: JSON = [:], webReads: Int = 1, preferenceReads: Int = 1,
         mouseCount: Int = 1, mouseButton: Int = 0, mouseDuration: Double = 0, mouseHeld: Bool = false) {
        self.name = name; self.expected = expected; self.native = native; self.force = force
        self.kind = kind; self.actions = actions; self.web = web; self.webThrows = webThrows
        self.menuSelected = menuSelected; self.menuAction = menuAction; self.options = options
        self.webReads = webReads; self.preferenceReads = preferenceReads
        self.mouseCount = mouseCount; self.mouseButton = mouseButton
        self.mouseDuration = mouseDuration; self.mouseHeld = mouseHeld
    }
}
private var scenario = Scenario("unset", "unset")
private var trace = [String](), deliveries = [String](), preferenceKeys = [String]()
private var webReads = 0
private var mouse: [String: Any]?
private var cursorReads = 0
private func fail(_ phase: String) throws { if scenario.fault == phase { throw ServiceError(.accessibilityError, "owned " + phase) } }

private final class OwnedDefaults: UserDefaults {
    override func object(forKey key: String) -> Any? {
        preferenceKeys.append(key); trace.append("force-flag")
        return key == "feature/computerUseAlwaysSimulateClick" ? scenario.force : nil
    }
}
private let defaults = OwnedDefaults(suiteName: "cua-owned-click-policy-" + UUID().uuidString)!
enum AXSettler { enum Polling: String { case applicationDefault, tenthSecond } }
enum RequestRuntime {
    static func check() throws {}
    static func wait(_ seconds: Double) throws { trace.append("wait:\(seconds)"); try fail("wait") }
}
enum CursorCapture { static var enabled: Bool { cursorReads += 1; trace.append("cursor-flag"); return scenario.cursor } }
enum SyntheticFocusSessions { static func prepare(app: String) throws { trace.append("prepare-focus"); try fail("prepare-focus") } }
enum AppResolver { static func require(_ bundle: String) throws -> String { bundle }; static func pid(for bundle: String) throws -> Int32 { 42 } }
enum AXPointerTarget { static func forElement(_ element: OwnedElement, hostPID: Int32) throws -> PointerTarget { trace.append("pointer"); try fail("pointer"); return PointerTarget() } }
enum NativeInteractionTargetPolicy { static func requireAllowed(element: OwnedElement) throws { trace.append("validate:\(element.id)"); try fail("validate") } }
enum AXNativeClickFocus {
    enum Delivery { case accessibility, mouse }
    static func prepare(_ element: OwnedElement, bundle: String, delivery: Delivery, heldKey: Bool, webShaped: () throws -> Bool) throws -> CGEventFlags {
        trace.append(delivery == .mouse ? "focus:mouse" : "focus:AX"); try fail("focus"); return []
    }
}
enum AXNativeElementActions {
    static func perform(_ element: OwnedElement, action: String) throws {
        trace.append("generic:\(element.id)"); try fail("action"); _ = AXUIElementPerformAction(element, action as CFString)
    }
}
enum AX {
    static func onElement<T>(_ element: OwnedElement, _ body: () throws -> T) throws -> T { try body() }
    static func actionNames(_ element: OwnedElement) -> [String] { trace.append("actions"); return scenario.actions }
    static func string(_ element: OwnedElement, _ key: String) -> String? { kAXMenuBarItemRole }
}
enum AXMenuSessions {
    static func select(_ element: OwnedElement, bundle: String) throws -> Bool {
        trace.append("menu-check"); try fail("menu")
        if scenario.menuSelected { trace.append("menu-select"); deliveries.append("menu") }
        return scenario.menuSelected
    }
    static func activate(_ element: OwnedElement, bundle: String) { trace.append("menu-activate") }
    static func closeSynthetic(_ bundle: String) { trace.append("menu-close") }
}
enum AXClickableTarget {
    static func secondaryPosition(_ element: OwnedElement, bundle: String) throws -> SecondaryCursorPreparation.Position {
        trace.append("reveal"); try fail("position")
        return .init(point: scenario.noPoint ? nil : CGPoint(x: 10, y: 20), scrolled: scenario.scrolled)
    }
    static func nativePoint(_ element: OwnedElement, bundle: String) throws -> CGPoint? {
        trace.append("point:\(element.id)"); try fail("point")
        return scenario.noPoint ? nil : CGPoint(x: 10, y: 20)
    }
    static func prepare(_ element: OwnedElement, bundle: String, refetch: () throws -> OwnedElement) throws -> OwnedTarget {
        trace.append("prepare"); return OwnedTarget()
    }
}
final class CursorOverlay {
    static let shared = CursorOverlay()
    func place(at point: CGPoint, targetWindowID: UInt32?) { trace.append("place") }
    func prepareInteraction() -> Bool { trace.append("create-cursor"); return scenario.visible }
    @discardableResult func press(animationDuration: TimeInterval = 0.12) -> Bool {
        trace.append("press:\(animationDuration)"); return scenario.visible
    }
}
func AXUIElementPerformAction(_ element: OwnedElement, _ action: CFString) -> OwnedAXError {
    let action = action as String
    trace.append(action); deliveries.append(action); return .success
}
extension Actions {
    static func nativeCoordinateClick(_ input: JSON, bundle: String, options: ClickOptions) throws -> AXSettler.Polling {
        trace.append("coordinate-dispatch")
        try mouseClick(at: CGPoint(x: 10, y: 20), options: options, target: PointerTarget())
        return .applicationDefault
    }
    static func elementIndex(from target: JSON) -> String? { scenario.kind == "element" ? "1" : nil }
    private static func secondaryTarget(_ target: JSON, bundle: String, native: Bool) throws -> SecondaryTarget {
        let id = trace.contains("reveal") ? 2 : 1
        trace.append("target:\(id)"); try fail(id == 1 ? "target" : "refetch")
        return SecondaryTarget(index: "1", element: OwnedElement(id), actions: nil, windowID: 77)
    }
    static func moveCursor(to point: CGPoint, bundle: String, windowID: UInt32?) throws {
        trace.append("move"); try fail("move"); trace.append("arrive"); if let enabled = scenario.cursorAfterMove { scenario.cursor = enabled }
    }
    static func activate(_ bundle: String) { trace.append("activate") }
    static func element(from target: JSON, bundle: String) throws -> OwnedElement? {
        scenario.kind == "element" ? OwnedElement() : nil
    }
    static func point(from target: JSON, bundle: String) throws -> (point: CGPoint, pointer: PointerTarget)? {
        scenario.kind == "coordinate" ? (CGPoint(x: 10, y: 20), PointerTarget()) : nil
    }
    static func webClickShape(_ element: OwnedElement, bundle: String) throws -> Bool { scenario.web }
    static func nativeMenuClickAction(_ element: OwnedElement) -> String? { scenario.menuAction }
    static func cursor(for bundle: String, enabled: Bool? = nil, _ body: () -> Void) { trace.append("cursor"); body() }
    static func webClickRequiresMouse(_ element: OwnedElement, at point: @autoclosure () throws -> CGPoint?, bundle: String) throws -> Bool {
        webReads += 1; trace.append("web")
        if scenario.webThrows { throw ServiceError(.accessibilityError, "owned web check failed") }
        if let enabled = scenario.cursorAfterWeb { scenario.cursor = enabled }
        return scenario.web
    }
    static func validateAXActionStatus(_ error: OwnedAXError, native: Bool, message: String) throws {
        if error != .success { throw ServiceError(.accessibilityError, message) }
    }
    static func nativeMouseClick(at point: CGPoint, options: ClickOptions, target: PointerTarget, bundle: String, cursorVisible: Bool, additionalFlags: CGEventFlags = []) throws {
        trace.append("native-mouse"); try mouseClick(at: point, options: options, target: target)
    }
    static func mouseClick(at point: CGPoint, options: ClickOptions, target: PointerTarget) throws {
        trace.append("mouse"); deliveries.append("mouse")
        mouse = ["count": options.count, "button": options.button, "duration": options.duration,
                 "held": options.chord != nil, "windowID": target.windowID]
    }
}

@main struct NativeClickPolicyTest {
    static func main() throws {
        let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let block: @convention(block) (AnyObject) -> AnyObject = { _ in defaults }
        let replacement = imp_implementationWithBlock(block), saved = method_getImplementation(method)
        method_setImplementation(method, replacement)
        defer { method_setImplementation(method, saved); imp_removeBlock(replacement) }
        var cases: [Scenario] = [
            .init("ordinary press", "AXPress"),
            .init("forced ordinary press", "mouse", force: true, webReads: 0),
            .init("pick precedes press", "AXPick", actions: ["AXPress", "AXPick"]),
            .init("forced pick", "mouse", force: true, actions: ["AXPress", "AXPick"], webReads: 0),
            .init("no AX action", "mouse", actions: [], webReads: 0),
            .init("web requires mouse", "mouse", web: true),
            .init("web error before input", "error", webThrows: true),
            .init("forced skips irrelevant web error", "mouse", force: true, webThrows: true, webReads: 0),
            .init("legacy keeps existing path", "AXPress", native: false, force: true, webReads: 0, preferenceReads: 0),
            .init("legacy does not use pick", "mouse", native: false, actions: ["AXPick"], webReads: 0, preferenceReads: 0),
            .init("coordinate", "mouse", kind: "coordinate", webReads: 0, preferenceReads: 0),
            .init("forced coordinate", "mouse", force: true, kind: "coordinate", webReads: 0, preferenceReads: 0),
            .init("menu selection shortcut", "menu", force: true, menuSelected: true, webReads: 0, preferenceReads: 0),
            .init("forced menu item uses mouse", "mouse", force: true, menuAction: "AXPress", webReads: 0),
            .init("right button", "mouse", options: ["mouseButton": 1], webReads: 0, mouseButton: 1),
            .init("double click", "mouse", options: ["clickCount": 2], webReads: 0, mouseCount: 2),
            .init("held click", "mouse", options: ["duration": 0.15], webReads: 0, mouseDuration: 0.15),
            .init("modifier click", "mouse", options: ["key": "Shift_L"], webReads: 0, mouseHeld: true),
            .init("invalid count before preference read", "error", options: ["clickCount": true], webReads: 0, preferenceReads: 0)
        ]
        // Failure boundaries and option presence are independently observable.
        for (name, changes) in [
            ("refetch precedes validation", { (s: inout Scenario) in s.scrolled = true }),
            ("disabled cursor still reveals", { (s: inout Scenario) in s.scrolled = true; s.cursor = false }),
            ("hidden cursor skips press wait", { (s: inout Scenario) in s.visible = false }),
            ("AX action without clickable center", { (s: inout Scenario) in s.noPoint = true }),
            ("AX action without pointer target", { (s: inout Scenario) in s.fault = "pointer" })
        ] {
            var item = Scenario(name, "AXPress"); changes(&item); cases.append(item)
        }
        var flagAfterMove = Scenario("fresh cursor flag after movement", "AXPress"); flagAfterMove.cursorAfterMove = false; cases.append(flagAfterMove)
        var flagAfterWeb = Scenario("retained cursor reference after web check", "AXPress"); flagAfterWeb.cursorAfterWeb = false; cases.append(flagAfterWeb)
        cases.append(Scenario("explicit zero hold uses mouse", "mouse", options: ["duration": 0], webReads: 0))
        cases.append(Scenario("null hold retains AX action", "AXPress", options: ["duration": NSNull()]))
        let legacyZero = Scenario("legacy explicit zero retains AX action", "AXPress", native: false, options: ["duration": 0], webReads: 0, preferenceReads: 0)
        cases.append(legacyZero)
        for phase in ["target", "position", "move", "refetch", "validate", "menu", "wait", "action", "point", "pointer"] {
            var item = Scenario("failure stops at " + phase, "error")
            item.fault = phase
            if phase == "refetch" { item.scrolled = true }
            if ["target", "position", "move", "refetch", "validate", "menu"].contains(phase) { item.webReads = 0; item.preferenceReads = 0 }
            if ["point", "pointer"].contains(phase) { item.force = true; item.webReads = 0 }
            cases.append(item)
        }
        var prepareFailure = Scenario("focus initialization failure precedes geometry", "error", webReads: 0, preferenceReads: 0); prepareFailure.fault = "prepare-focus"; cases.append(prepareFailure)
        var axFocusFailure = Scenario("AX focus failure prevents action", "error"); axFocusFailure.fault = "focus"; cases.append(axFocusFailure)
        var mouseFocusFailure = Scenario("mouse focus failure prevents delivery", "error", force: true, webReads: 0); mouseFocusFailure.fault = "focus"; cases.append(mouseFocusFailure)
        var offscreen = Scenario("physical delivery without center errors", "error", force: true, webReads: 0)
        offscreen.noPoint = true; cases.append(offscreen)
        var rows = [[String: Any]]()
        for item in cases {
            scenario = item; trace = []; deliveries = []; preferenceKeys = []; webReads = 0; mouse = nil; cursorReads = 0
            let input = item.options.merging(["at": ["elementID": ["_0": "1"]]]) { _, value in value }
            var failed = false
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do { _ = try Actions.fixtureClick(input, native: item.native) }
                catch { failed = true; trace.append("error") }
                semaphore.signal()
            }
            semaphore.wait()
            let delivered = failed ? "error" : deliveries.joined(separator: ",")
            var matches = delivered == item.expected && webReads == item.webReads && preferenceKeys.count == item.preferenceReads
            matches = matches && preferenceKeys.allSatisfy { $0 == "feature/computerUseAlwaysSimulateClick" }
            if item.expected == "mouse" {
                let expectedMouse: [String: Any] = ["count": item.mouseCount, "button": item.mouseButton,
                    "duration": item.mouseDuration, "held": item.mouseHeld, "windowID": UInt32(77)]
                matches = matches && mouse.map { NSDictionary(dictionary: $0).isEqual(to: expectedMouse) } == true
            }
            if item.native, item.kind == "element", !failed {
                func before(_ first: String, _ second: String) -> Bool {
                    guard let a = trace.firstIndex(of: first), let b = trace.firstIndex(of: second) else { return false }; return a < b
                }
                let id = item.scrolled ? 2 : 1
                matches = matches && before("prepare-focus", "reveal")
                matches = matches && before("reveal", "validate:\(id)")
                if !item.noPoint && item.cursor { matches = matches && before("arrive", "validate:\(id)") }
                if item.scrolled { matches = matches && before("target:2", "validate:2") }
                if item.expected.hasPrefix("AX") {
                    matches = matches && !trace.contains("pointer") && before("focus:AX", "generic:\(id)")
                    if (item.cursorAfterMove ?? item.cursor) && item.visible { matches = matches && before("wait:0.05", "generic:\(id)") && trace.filter { $0 == "wait:0.05" }.count == 2 }
                    else { matches = matches && !trace.contains("press:0.05") && !trace.contains("wait:0.05") }
                }
                if item.cursorAfterMove == false { matches = matches && !trace.contains("create-cursor") }
                if item.expected != "menu" { matches = matches && before("validate:\(id)", "force-flag") }
                if item.expected == "mouse" { matches = matches && before("pointer", "focus:mouse") && before("focus:mouse", "native-mouse") && !trace.contains("activate") }
                if item.expected == "menu" { matches = matches && before("validate:\(id)", "menu-select") }
            }
            if item.native, item.kind == "coordinate", !failed {
                matches = matches && trace.contains("coordinate-dispatch") && !trace.contains("activate")
            }
            if failed { matches = matches && deliveries.isEmpty }
            let row: [String: Any] = ["name": item.name, "passed": matches, "delivery": delivered,
                "expectedDelivery": item.expected, "webReads": webReads, "expectedWebReads": item.webReads,
                "preferenceKeys": preferenceKeys, "expectedPreferenceReads": item.preferenceReads,
                "mouse": mouse as Any? ?? NSNull(), "trace": trace]
            rows.append(row); print("\(matches ? "PASS" : "FAIL") native click policy \(item.name)")
        }
        let passed = rows.filter { ($0["passed"] as? Bool) == true }.count
        let report: [String: Any] = ["cases": rows.count, "passed": passed, "failed": rows.count - passed,
            "results": rows, "nativeInput": false, "platformUIUsed": false]
        try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if passed != rows.count && !CommandLine.arguments.contains("--observe") { exit(1) }
    }
}
