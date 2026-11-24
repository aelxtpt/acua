import CoreGraphics
import Foundation

// Unit tests for choosing the window a mouse event is addressed to, with a
// fake accessibility backend. No events are posted.

private enum FakeAXError: Error { case illegalArgument }

/// Nodes are plain strings. "field" plays a WebKit form field: AX cannot report
/// a window for it (AXUIElementGetWindow fails with -25201), as for every
/// element owned by the WebContent process.
@MainActor private struct FakeBackend: ControllerMouseEventTargetBackend {
    typealias Node = String

    let hostPID: Int32 = 100
    let windowIDs: [String: UInt32] = ["window": 7, "button": 7]
    let pids: [String: Int32] = ["application": 100, "window": 100, "field": 100, "button": 100]

    func ordinaryPID(_ application: String) throws -> Int32 { hostPID }
    func actualPID(_ node: String) throws -> Int32 { pids[node] ?? 0 }

    func windowID(_ node: String) throws -> UInt32 {
        guard let id = windowIDs[node] else { throw FakeAXError.illegalArgument }
        return id
    }

    func optionalWindowID(_ node: String) throws -> UInt32? { windowIDs[node] }
    func children(_ node: String) -> [String] { [] }
    func parent(_ node: String) -> String? { node == "window" ? nil : "window" }
    func role(_ node: String) -> String { node == "window" ? "AXWindow" : "AXTextField" }
    func bundleIdentifier(_ application: String) -> String? { "com.example.web" }
    func frame(_ window: String) -> CGRect? { CGRect(x: 10, y: 20, width: 300, height: 200) }
    func processKind(_ pid: Int32) -> ControllerMouseProcessKind { .application }
    func missingContainingProcess() {}
    func frontWindowID(at point: CGPoint) -> UInt32? { nil }
    func systemElement(at point: CGPoint) throws -> String? { nil }
    func windowBounds(_ id: UInt32) -> CGRect? { nil }
}

@main
enum AcuaMouseEventTargetTests {
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

    @MainActor static func main() {
        let targeting = ControllerMouseEventTargeting(backend: FakeBackend())
        let point = CGPoint(x: 50, y: 60)

        do {
            let target = try targeting.target(at: point, application: "application", window: "window", element: "button")
            check("MouseTarget_ElementWithWindow_UsesItsWindow", target.windowID == 7 && target.element == "button")
        } catch {
            check("MouseTarget_ElementWithWindow_UsesItsWindow", false, "\(error)")
        }

        do {
            let target = try targeting.target(at: point, application: "application", window: "window", element: "field")
            check("MouseTarget_ElementWithoutWindow_FallsBackToTheSelectedWindow",
                  target.windowID == 7 && target.element == "field" && target.pid == 100, "\(target)")
        } catch {
            check("MouseTarget_ElementWithoutWindow_FallsBackToTheSelectedWindow", false, "\(error)")
        }

        print("\(passed) mouse event target tests passed")
    }
}
