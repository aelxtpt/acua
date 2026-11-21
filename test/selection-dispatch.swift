import Foundation
import CoreGraphics
import Darwin

typealias JSON = [String: Any]
typealias CFString = String
typealias CFTypeRef = AnyObject
struct CFRange { var location: Int; var length: Int }
enum ErrorCode { case accessibilityError, unknownError, unhandledEvent, noActiveSession }
struct ServiceError: Error { let code: ErrorCode; let message: String; init(_ code: ErrorCode, _ message: String) { self.code = code; self.message = message } }
func str(_ value: Any?) -> String? { value as? String }
func asDict(_ value: Any?) -> JSON? { value as? JSON }
let kAXSelectedTextRangeAttribute = "AXSelectedTextRange", kAXValueAttribute = "AXValue"
let kAXBoundsForRangeParameterizedAttribute = "AXBoundsForRange", kAXRoleAttribute = "AXRole", kAXParentAttribute = "AXParent"
let kCFBooleanTrue: AnyObject = NSNumber(value: true)
enum Status: Int { case success = 0, cannotComplete = -25204, attributeUnsupported = -25205, failure = -25200 }
enum ValueKind { case cfRange, cgRect }
final class AXValue: NSObject {
    let kind: ValueKind
    var range: CFRange?, rect: CGRect?
    init(_ range: CFRange) { kind = .cfRange; self.range = range }
    init(_ rect: CGRect) { kind = .cgRect; self.rect = rect }
}
final class AXUIElement: NSObject {
    var role: String? = "AXTextArea", actions = [String](), parent: AXUIElement?
    var text = "😀 Olá mundo", settable = true, revealSettable = false
    var selectionStatus = Status.success, actionStatus = Status.success, attributeStatus = Status.success
    var bounds: [CGRect?] = [CGRect(x: 20, y: 30, width: 15, height: 10)]
    var boundsReads = 0, visible = true, scrollChanged = false
    var actualPID: Int32? = 42
}
struct AXReference: Hashable {
    let identity: ObjectIdentifier
    init(element: AXUIElement) { identity = ObjectIdentifier(element) }
}
enum State {
    static var trace = [String](), position: CGPoint?, selected: CFRange?
    static var cancelled = false, cancelAtWait = false, createFailure = false
    static var time = 0.0
    static var motionCompleted = true, motionDelay = 0.02
    static var threads = [Bool]()
    static var cursorWindows = [UInt32?]()
    static func reset() {
        trace = []; position = nil; selected = nil; cancelled = false; cancelAtWait = false
        createFailure = false; time = 0; motionCompleted = true; motionDelay = 0.02; threads = []; cursorWindows = []
        CursorCapture.enabled = true
    }
}
func AXValueCreate(_ kind: ValueKind, _ pointer: UnsafeRawPointer) -> AXValue? {
    if State.createFailure { return nil }
    return kind == .cfRange ? AXValue(pointer.load(as: CFRange.self)) : AXValue(pointer.load(as: CGRect.self))
}
func AXValueGetValue(_ value: AXValue, _ kind: ValueKind, _ pointer: UnsafeMutableRawPointer) -> Bool {
    guard kind == value.kind else { return false }
    if kind == .cgRect, let rect = value.rect { pointer.storeBytes(of: rect, as: CGRect.self); return true }
    if kind == .cfRange, let range = value.range { pointer.storeBytes(of: range, as: CFRange.self); return true }
    return false
}
func AXUIElementIsAttributeSettable(_ el: AXUIElement, _ attribute: String, _ output: inout DarwinBoolean) -> Status {
    State.trace.append(attribute == kAXSelectedTextRangeAttribute ? "settable" : "reveal-settable")
    State.threads.append(Thread.isMainThread)
    output = DarwinBoolean(attribute == kAXSelectedTextRangeAttribute ? el.settable : el.revealSettable)
    return .success
}
func AXUIElementCopyParameterizedAttributeValue(_ el: AXUIElement, _ attribute: String, _ value: AXValue, _ output: inout CFTypeRef?) -> Status {
    State.trace.append("bounds"); State.threads.append(Thread.isMainThread)
    let index = el.boundsReads; el.boundsReads += 1
    guard index < el.bounds.count, let rect = el.bounds[index] else { return .failure }
    output = AXValue(rect); return .success
}
func AXUIElementPerformAction(_ el: AXUIElement, _ action: String) -> Status {
    State.trace.append("scroll-action"); State.threads.append(Thread.isMainThread); return el.actionStatus
}
func AXUIElementSetAttributeValue(_ el: AXUIElement, _ attribute: String, _ value: AnyObject) -> Status {
    State.threads.append(Thread.isMainThread)
    if attribute == kAXSelectedTextRangeAttribute {
        State.trace.append("write"); State.selected = (value as? AXValue)?.range; return el.selectionStatus
    }
    State.trace.append("scroll-attribute"); return el.attributeStatus
}
enum AccessibilityWindowSPI {
    static func actualPID(_ el: AXUIElement) throws -> Int32 {
        guard let pid = el.actualPID else { throw ServiceError(.unknownError, "unknown PID") }; return pid
    }
}
enum RequestRuntime {
    static func serialized<T>(app: String, _ body: () throws -> T) rethrows -> T { try body() }
    static func check() throws { if State.cancelled { throw ServiceError(.unknownError, "cancelled") } }
    static func onMainThread<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
    static func wait(_ duration: Double) throws { try check(); State.time += duration }
    static func wait(for signal: DispatchSemaphore, maximumSeconds: Double) throws {
        State.trace.append("wait")
        if State.cancelAtWait { throw ServiceError(.unknownError, "cancelled at wait") }
        guard signal.wait(timeout: .now() + min(1, maximumSeconds)) == .success else { throw ServiceError(.unknownError, "timeout") }
        try check()
    }
}
enum ProcessInfo {
    static let processInfo = Info()
    struct Info { var systemUptime: Double { State.time } }
}
enum AX {
    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        if attribute == kAXRoleAttribute { return el.role }
        State.trace.append("text"); return el.text
    }
    static func copy(_ el: AXUIElement, _ attribute: String) -> AnyObject? { el.parent }
    static func axElement(_ value: AnyObject?) -> AXUIElement? { value as? AXUIElement }
    static func axValue(_ value: AnyObject?) -> AXValue? { value as? AXValue }
    static func actionNames(_ el: AXUIElement) -> [String] { el.actions }
    /* AX */
}
enum AXClickableTarget {
    private static func point(_ el: AXUIElement, chessApplication: AXUIElement?, requireDisplay: Bool = true) throws -> CGPoint? {
        State.trace.append(requireDisplay ? "wrong-display-check" : "visibility"); return el.visible ? .zero : nil
    }
    private static func scrollArea(_ el: AXUIElement, target: CGRect) throws -> Bool {
        State.trace.append("scroll-area"); return el.scrollChanged
    }
    /* SCROLL */
}
struct EventStreamNativeWindow { let id: UInt32; let frame: CGRect }
enum AppResolver { static func require(_ bundle: String) throws -> String { bundle } }
enum AXCapture { static func processKey(_ app: String) -> String { "current-process" } }
enum NativeAutomationTree {
    static func onMain<T>(_ body: () throws -> T) throws -> T { try RequestRuntime.onMainThread(body) }
}
enum AXIndex {
    static let shared = Index()
    final class Index {
        var native = true
        var el = AXUIElement()
        var window = EventStreamNativeWindow(id: 77, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var processKey = "current-process", ownerAvailable = true
        struct Observed { let nativeTree: Int?; let processKey: String }
        func snapshot(for bundle: String) -> Observed? {
            State.trace.append("resolve"); return Observed(nativeTree: native ? 1 : nil, processKey: processKey)
        }
        struct OwnerState { let nativeOwner: Owner? }
        func state(_ bundle: String) -> OwnerState { OwnerState(nativeOwner: ownerAvailable ? Owner(index: self) : nil) }
        struct Selection { let applicationWindow: ApplicationWindow }
        struct ApplicationWindow { let nativeWindow: EventStreamNativeWindow }
        struct Snapshot {
            let selection: Selection, text: String
            func sourceRange(for id: Int, text: String, prefix: String?, suffix: String?, selection: String) throws -> NSRange {
                State.trace.append("source-range")
                return try TextSelection.range(in: self.text, text: text, prefix: prefix, suffix: suffix, selection: selection)
            }
        }
        struct Resolved { let element: AXUIElement; let snapshot: Snapshot; let id: Int }
        struct Owner {
            let index: Index
            func resolve(_ id: Int, in native: Int, app: String, ignoreValueChange: Bool) throws -> Resolved {
                State.trace.append("owner-resolve")
                return Resolved(element: index.el, snapshot: Snapshot(selection: Selection(applicationWindow: ApplicationWindow(nativeWindow: index.window)), text: index.el.text), id: id)
            }
        }
        /* INDEX */
    }
}
enum CursorCapture { static var enabled = true }
final class CursorOverlay {
    static let shared = CursorOverlay()
    func place(at point: CGPoint, targetWindowID: UInt32?, nextInteractionTiming: CursorInteractionTiming = .finished, completion: @escaping (Bool) -> Void) {
        State.trace.append("motion-start"); State.position = point
        State.cursorWindows.append(targetWindowID)
        let completed = State.motionCompleted
        DispatchQueue.main.asyncAfter(deadline: .now() + State.motionDelay) {
            State.trace.append("motion-end"); completion(completed)
        }
    }
}
enum Actions {
    static func element(from a: JSON, bundle: String, ignoreValueChange: Bool) throws -> AXUIElement? { AXIndex.shared.el }
    static func keyboardPID(_ bundle: String, element: AXUIElement) throws -> Int32 { State.trace.append("focus"); try RequestRuntime.check(); return 42 }
    private static func cursor(for bundle: String, enabled: Bool? = nil, _ update: () -> Void) { if enabled ?? CursorCapture.enabled { update() } }
    static func run(native: Bool = true, text: String = "Olá", selection: String = "text", id: String = "1") throws { try selectText(["elementID": ["_0": id], "text": text, "selection": selection], bundle: "owned.fixture", native: native) }
    static func position(_ point: CGPoint, windowID: UInt32? = 77) throws { try moveCursor(to: point, bundle: "owned.fixture", windowID: windowID) }
    /* ACTIONS */
}

@main struct DispatchTests {
    static func main() throws {
        var rows = [[String: Any]]()
        func check(_ ok: Bool, _ name: String) { rows.append(["name": name, "passed": ok]); print("\(ok ? "PASS" : "FAIL") selection dispatch \(name)") }
        func reset() -> AXUIElement {
            State.reset(); let el = AXUIElement(); AXIndex.shared.el = el; AXIndex.shared.native = true
            AXIndex.shared.processKey = "current-process"; AXIndex.shared.ownerAvailable = true
            AXIndex.shared.window = EventStreamNativeWindow(id: 77, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            return el
        }
        // Work happens on the service's connection worker while the main loop
        // handles the owned animation completion and same-process AX callbacks.
        func worker(_ body: @escaping () throws -> Void) -> Error? {
            let lock = NSLock(); var done = false; var failure: Error?
            Thread.detachNewThread {
                do { try body() } catch { failure = error }
                lock.lock(); done = true; lock.unlock()
            }
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                lock.lock(); let finished = done; lock.unlock()
                if finished { return failure }
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            fatalError("owned worker exceeded deadline")
        }
        _ = reset()
        check(worker { try Actions.run() } == nil && State.trace == ["resolve", "owner-resolve", "settable", "source-range", "bounds", "motion-start", "wait", "motion-end", "focus", "write"] && State.position == CGPoint(x: 35, y: 40), "actual dispatch waits for cursor completion before focus and write")
        var el = reset(); el.bounds = [nil]
        check(worker { try Actions.run() } == nil && State.trace == ["resolve", "owner-resolve", "settable", "source-range", "bounds", "focus", "write"], "initial bounds failure skips visual work and still selects")
        el = reset(); el.actions = ["AXScrollToVisible"]; el.bounds.append(CGRect(x: 90, y: 95, width: 40, height: 20))
        check(worker { try Actions.run() } == nil && el.boundsReads == 2 && State.position == CGPoint(x: 100, y: 100) && State.trace.firstIndex(of: "scroll-action")! < State.trace.firstIndex(of: "motion-start")!, "scroll then fresh bounds then clamped lower-right point")
        el = reset(); el.actions = ["AXScrollToVisible"]; el.bounds.append(nil)
        check(worker { try Actions.run() } == nil && State.position == CGPoint(x: 35, y: 40), "post-scroll bounds error retains initial rectangle")
        for status in [Status.success, .cannotComplete, .attributeUnsupported] {
            el = reset(); el.actions = ["AXScrollToVisible"]; el.actionStatus = status
            check(worker { try Actions.run() } == nil && State.trace.contains("write"), "perform action status \(status.rawValue) accepted")
        }
        el = reset(); el.actions = ["AXScrollToVisible"]; el.actionStatus = .failure
        check(worker { try Actions.run() } != nil && !State.trace.contains("motion-start") && !State.trace.contains("focus") && !State.trace.contains("write"), "scroll action failure stops selection")
        for status in [Status.cannotComplete, .attributeUnsupported, .failure] {
            el = reset(); el.role = "AXCell"; el.revealSettable = true; el.attributeStatus = status
            check(worker { try Actions.run() } != nil && State.trace.contains("scroll-attribute") && !State.trace.contains("write"), "attribute status \(status.rawValue) propagates")
        }
        el = reset(); el.role = "AXCell"; el.revealSettable = true
        check(worker { try Actions.run() } == nil && State.trace.contains("scroll-attribute") && State.trace.contains("write"), "successful cell attribute proceeds")
        el = reset(); el.role = "AXScrollArea"; el.scrollChanged = true
        check(worker { try Actions.run() } == nil && State.trace.contains("scroll-area") && el.boundsReads == 2, "scroll-area provider participates in actual plan execution")
        el = reset(); el.actions = ["AXScrollToVisible"]; el.visible = false
        check(worker { try Actions.run() } == nil && State.time >= 0.5 && State.trace.contains("write") && !State.trace.contains("wrong-display-check"), "visibility poll timeout is nonfatal and skips display validation")
        _ = reset(); CursorCapture.enabled = false
        check(worker { try Actions.run() } == nil && State.trace == ["resolve", "owner-resolve", "settable", "source-range", "focus", "write"], "disabled cursor keeps selection without bounds or scrolling")
        _ = reset()
        check(worker { try Actions.run(native: false) } == nil && State.trace == ["resolve", "owner-resolve", "settable", "source-range", "focus", "write"], "legacy request skips native cursor preparation")
        _ = reset(); State.motionCompleted = false
        check(worker { try Actions.run() } == nil && State.trace.suffix(3) == ["motion-end", "focus", "write"], "interrupted motion releases selection continuation")
        _ = reset(); State.cancelAtWait = true
        check(worker { try Actions.run() } != nil && !State.trace.contains("focus") && !State.trace.contains("write"), "request cancellation abandons pending completion before focus")
        // Drain the cancelled owned callback before resetting its storage.
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.04))
        el = reset(); el.selectionStatus = .failure
        check(worker { try Actions.run() } != nil && State.trace.suffix(2) == ["focus", "write"], "final AX write failure propagates")
        _ = reset()
        check(worker { try Actions.position(CGPoint(x: CGFloat.nan, y: 3)) } != nil && State.trace.isEmpty, "nonfinite cursor position rejected before scheduling")
        _ = reset()
        do { try Actions.position(.zero); check(false, "main-thread wait rejected") } catch { check(State.trace.isEmpty, "main-thread wait rejected") }
        el = reset(); AXIndex.shared.native = false
        check(worker { try Actions.run() } == nil && State.trace == ["resolve", "settable", "text", "focus", "write"] && State.selected?.location == 3 && State.selected?.length == 3, "fallback preserves UTF-16 offsets and checks support before text")
        el = reset(); AXIndex.shared.native = false; el.settable = false
        check(worker { try Actions.run(text: "missing") } != nil && State.trace == ["resolve", "settable"], "unsupported selection precedes text search failure")
        for (pid, expectedMain) in [(getpid() as Int32?, true), (Int32(42) as Int32?, false), (nil, false)] {
            el = reset(); el.actualPID = pid
            check(worker { try AX.requireTextSelectionSettable(el) } == nil && State.threads == [expectedMain], "AX settable routing PID \(String(describing: pid))")
            State.threads = []
            check(worker { _ = AX.boundsForRange(el, range: NSRange(location: 1, length: 2)) } == nil && State.threads == [expectedMain], "AX bounds routing PID \(String(describing: pid))")
        }
        el = reset(); el.parent = el
        check(worker { try Actions.run() } != nil && !State.trace.contains("scroll-action") && !State.trace.contains("write"), "cyclic ancestry rejected before effects")
        el = reset(); el.settable = false
        check(worker { try Actions.run(text: "missing") } != nil && State.trace == ["resolve", "owner-resolve", "settable"], "native settable check precedes range lookup")
        _ = reset(); AXIndex.shared.processKey = "old-process"
        check(worker { try Actions.run() } != nil && State.trace == ["resolve"], "restarted application rejected before owner resolution")
        _ = reset(); AXIndex.shared.ownerAvailable = false
        check(worker { try Actions.run() } != nil && State.trace == ["resolve"], "missing native owner rejected before selection")
        for id in ["-1", "01", "1.0", "invalid"] {
            _ = reset()
            check(worker { try Actions.run(id: id) } != nil && State.trace == ["resolve"], "noncanonical element ID \(id) rejected")
        }
        _ = reset(); AXIndex.shared.window = EventStreamNativeWindow(id: 88, frame: CGRect(x: 500, y: 600, width: 100, height: 100))
        check(worker { try Actions.run() } == nil && State.position == CGPoint(x: 500, y: 600), "current resolved snapshot supplies selection window geometry")
        _ = reset()
        check(worker {try Actions.position(.zero,windowID:nil)} == nil && State.cursorWindows.count == 1 && State.cursorWindows[0] == nil && State.trace == ["motion-start","wait","motion-end"], "shared movement forwards absent target window and awaits completion")
        let passed = rows.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["passed": passed, "failed": rows.count - passed, "checks": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if passed != rows.count { exit(1) }
    }
}
