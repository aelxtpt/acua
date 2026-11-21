import Foundation
import ApplicationServices

enum AXNativeElementActions {
    static func perform(_ element: AXUIElement, action: String) throws {
        do { try NativeElementAction.perform(element, action: action, backend: Backend()) }
        catch NativeElementAction.Failure.cyclicActionDependency {
            throw ServiceError(.accessibilityError, "Cyclic accessibility action dependency")
        }
    }

    private struct Backend: NativeElementActionBackend {
        func identity(_ element: AXUIElement) -> AXReference { AXReference(element: element) }
        func role(_ element: AXUIElement) throws -> String? { try AX.onElement(element) { AX.string(element, "AXRole") } }
        func subrole(_ element: AXUIElement) throws -> String? { try AX.onElement(element) { AX.string(element, "AXSubrole") } }
        func parent(_ element: AXUIElement) throws -> AXUIElement? {
            try AX.onElement(element) { AX.axElement(AX.copy(element, "AXParent")) }
        }
        func children(_ element: AXUIElement) throws -> [AXUIElement] {
            try AX.onElement(element) { AX.children(element) }
        }
        private func supported(_ element: AXUIElement) -> Set<String> {
            var names: CFArray?
            _ = AXUIElementCopyAttributeNames(element, &names)
            return Set((names as? [String]) ?? [])
        }
        func childrenPreferringVisible(_ element: AXUIElement) throws -> [AXUIElement] {
            try AX.onElement(element) {
                let names = supported(element)
                var selected: String?
                for name in ["AXVisibleRows", "AXVisibleChildren"] where names.contains(name) {
                    var count: CFIndex = 0
                    if AXUIElementGetAttributeValueCount(element, name as CFString, &count) == .success, count > 0 {
                        selected = name; break
                    }
                }
                let attribute = selected ?? (names.contains("AXChildren") ? "AXChildren" : nil)
                guard let attribute, let raw = AX.copy(element, attribute) as? [AnyObject] else { return [] }
                return raw.compactMap(AX.axElement)
            }
        }
        func actions(_ element: AXUIElement) throws -> [String] { try AX.onElement(element) { AX.actionNames(element) } }
        func canDisclose(_ element: AXUIElement) throws -> Bool {
            try AX.onElement(element) {
                guard supported(element).contains("AXDisclosing") else { return false }
                var result: DarwinBoolean = false
                return AXUIElementIsAttributeSettable(element, "AXDisclosing" as CFString, &result) == .success && result.boolValue
            }
        }
        func isDisclosing(_ element: AXUIElement) throws -> Bool {
            try AX.onElement(element) { (AX.copy(element, "AXDisclosing") as? Bool) ?? false }
        }
        func setDisclosing(_ value: Bool, for element: AXUIElement) throws {
            let status = try AX.onElement(element) {
                AXUIElementSetAttributeValue(element, "AXDisclosing" as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
            }
            guard status == .success else {
                throw ServiceError(.accessibilityError, "Failed to set disclosure (\(status.rawValue))")
            }
        }
        func scrollBar(_ element: AXUIElement, vertical: Bool) throws -> AXUIElement? {
            try AX.onElement(element) { AX.axElement(AX.copy(element, vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar")) }
        }
        func performAX(_ action: String, on element: AXUIElement) throws {
            let status = try AX.onElement(element) { AXUIElementPerformAction(element, action as CFString) }
            guard status == .success || status == .cannotComplete || status == .attributeUnsupported else {
                throw ServiceError(.accessibilityError, "Failed to perform \(action) (\(status.rawValue))")
            }
        }
        func checkpoint() throws { try RequestRuntime.check() }
    }
}
