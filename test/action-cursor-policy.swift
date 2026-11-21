import Foundation

// Owned providers for the actual Actions coordinator fragment. No AppKit,
// accessibility, input, capture or preferences APIs are used by this fixture.
enum CursorCapture {
    struct Reference { let windowID: UInt32; let revision: UUID }
    static var enabled = true
    static var lookup: () -> UInt32? = { nil }
    static var lookups = 0
    static func visibleWindowID() -> UInt32? { lookups += 1; return lookup() }
}
final class CursorOverlay {
    static let shared = CursorOverlay()
    var hides = 0
    func hide() { hides += 1 }
}

@main struct ActionCursorPolicyTest {
    static func main() throws {
        var results = [[String: Any]]()
        func check(_ pass: Bool, _ name: String) {
            results.append(["name": name, "passed": pass])
            print("\(pass ? "PASS" : "FAIL") action cursor \(name)")
        }
        func reset() {
            Actions.fixtureReset()
            CursorCapture.enabled = true; CursorCapture.lookups = 0; CursorCapture.lookup = { nil }
            CursorOverlay.shared.hides = 0
        }

        reset()
        let initial = Actions.fixtureState()
        CursorCapture.enabled = false
        var updates = 0
        Actions.fixtureUpdate("a") { updates += 1 }
        let disabled = Actions.fixtureState()
        check(updates == 0, "disabled skips visual callback")
        check(disabled.0 == nil && disabled.1 == initial.1, "disabled leaves ownership and revision untouched")
        Actions.fixtureUpdate("a", enabled: true) { updates += 1 }
        check(updates == 1 && Actions.fixtureState().0 == "a", "captured enabled flag survives later preference changes")
        CursorCapture.enabled = true
        Actions.fixtureUpdate("b", enabled: false) { updates += 1 }
        check(updates == 1 && Actions.fixtureState().0 == "a", "captured disabled flag never starts a visual update")

        reset(); updates = 0
        let before = Actions.fixtureState().1
        Actions.fixtureUpdate("a") { updates += 1 }
        let owned = Actions.fixtureState()
        check(updates == 1 && owned.0 == "a" && owned.1 != before, "enabled claims ownership and updates once")
        CursorCapture.enabled = false
        Actions.fixtureUpdate("b") { updates += 1 }
        let skipped = Actions.fixtureState()
        check(updates == 1 && skipped.0 == "a" && skipped.1 == owned.1, "disabled preserves an existing owner")
        check(CursorOverlay.shared.hides == 0, "disabled update does not invent a hide operation")

        reset()
        Actions.fixtureUpdate("a") {}
        check(Actions.cursorForCapture("b") == nil && CursorCapture.lookups == 0,
              "other app cannot look up the cursor window")
        CursorCapture.enabled = false
        check(Actions.cursorForCapture("a") == nil && CursorCapture.lookups == 0,
              "disabled capture never looks up a window")
        CursorCapture.enabled = true
        check(Actions.cursorForCapture("a") == nil && CursorCapture.lookups == 1,
              "missing window produces no capture reference")
        CursorCapture.lookup = { 42 }
        let reference = Actions.cursorForCapture("a")!
        check(reference.windowID == 42 && reference.revision == Actions.fixtureState().1,
              "visible owned window returns the current revision")
        check(Actions.cursorIsCurrent(reference, for: "a") && !Actions.cursorIsCurrent(reference, for: "b"),
              "capture reference belongs to exactly its owner")
        Actions.fixtureUpdate("a") {}
        check(!Actions.cursorIsCurrent(reference, for: "a"), "next update invalidates an old reference")
        CursorCapture.lookup = { Actions.fixtureUpdate("b") {}; return 42 }
        check(Actions.cursorForCapture("a") == nil && Actions.fixtureState().0 == "b",
              "ownership can change during window lookup without deadlock or a stale capture")

        let beforeWrongHide = Actions.fixtureState()
        Actions.hideCursor(for: "a")
        check(CursorOverlay.shared.hides == 0 && Actions.fixtureState().1 == beforeWrongHide.1,
              "unrelated app cannot hide or invalidate the owner")
        CursorCapture.enabled = false
        Actions.hideCursor(for: "b")
        let cleared = Actions.fixtureState()
        check(CursorOverlay.shared.hides == 1 && cleared.0 == nil && cleared.1 != beforeWrongHide.1,
              "owner cleanup still hides after preference is disabled")
        Actions.hideCursor(for: "b")
        check(CursorOverlay.shared.hides == 1 && Actions.fixtureState().1 == cleared.1,
              "repeated owner cleanup is idempotent")

        let failed = results.filter { ($0["passed"] as? Bool) != true }.count
        let report: [String: Any] = ["cases": results.count, "passed": results.count - failed,
                                   "failed": failed, "results": results, "nativeInput": false,
                                   "platformUIUsed": false]
        try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if failed > 0 { exit(1) }
    }
}
