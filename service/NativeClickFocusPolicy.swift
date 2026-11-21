import Foundation

enum NativeClickFocusPolicy {
    enum Delivery { case accessibility, mouse }
    static let backgroundMouseFlag: UInt64 = 0x100000
    static let selectionAttributes: Set<String> = ["AXSelectedRows", "AXSelectedCells", "AXSelectedChildren"]

    static func mayCauseSelection<Element>(_ element: Element,
        role: (Element) throws -> String?, selectable: (Element) throws -> Bool,
        supported: (Element) throws -> Set<String>, parent: @escaping (Element) -> Element?,
        checkpoint: () throws -> Void) throws -> Bool {
        for node in AXParentChain(start: element, parent: parent) {
            try checkpoint()
            if try role(node) == "AXApplication" { return false }
            if try selectable(node) { return true }
            if try !supported(node).isDisjoint(with: selectionAttributes) { return true }
        }
        return false
    }

    static func prepare(_ delivery: Delivery, focused: Bool?, heldKey: Bool,
        actualActive: () throws -> Bool, webShaped: () throws -> Bool,
        catalyst: () throws -> Bool, maySelect: () throws -> Bool,
        menuButton: () throws -> Bool, enforce: () throws -> Void) throws -> UInt64 {
        guard let focused else {
            let active = try actualActive()
            return delivery == .mouse && !active ? backgroundMouseFlag : 0
        }
        guard !focused else { return 0 }
        if delivery == .accessibility {
            if try catalyst(), try maySelect() || menuButton() { try enforce() }
            return 0
        }
        // Preserve the short-circuit order and the second selection
        // query in the Catalyst branch.
        if try heldKey || webShaped() || maySelect() {
            try enforce(); return 0
        }
        if try catalyst(), try maySelect() || menuButton() {
            try enforce(); return 0
        }
        return backgroundMouseFlag
    }
}
