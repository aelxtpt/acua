import Foundation

// Concrete MenuUIElement branch. The selected menu kind must
// survive pointer hit refinement even when its delivery window/PID changes.
enum NativeMenuClick {
    static func requiresMouseMovement(isMenu: Bool) -> Bool { !isMenu }

    static func perform<Element>(isMenu: Bool, hasHoldDuration: Bool, hasHeldKey: Bool,
        hit: Element?, actions: (Element) throws -> [String], press: (Element) throws -> Void) throws -> Bool {
        guard isMenu else { return false }
        guard !hasHoldDuration, !hasHeldKey else {
            throw ServiceError(.unknownError, "Menu mouse action not supported")
        }
        guard let hit, try actions(hit).contains("AXPress") else {
            throw ServiceError(.unknownError, "Failed to click menu item")
        }
        try press(hit)
        return true
    }
}
