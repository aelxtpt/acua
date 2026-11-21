import AppKit
import ApplicationServices

enum AXNativeClickFocus {
    private static func supported(_ element: AXUIElement) throws -> Set<String> {
        try AX.onElement(element) {
            var names: CFArray?
            guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
            return Set((names as? [String]) ?? [])
        }
    }

    static func mayCauseSelection(_ element: AXUIElement) throws -> Bool {
        try NativeClickFocusPolicy.mayCauseSelection(element,
            role: { node in try AX.onElement(node) { AX.string(node, kAXRoleAttribute as String) } },
            selectable: { node in
                try AX.onElement(node) {
                    let role = AX.string(node, kAXRoleAttribute as String)
                    guard role != kAXMenuItemRole as String, role != kAXMenuBarItemRole as String,
                          try supported(node).contains(kAXSelectedAttribute as String) else { return false }
                    var settable: DarwinBoolean = false
                    return AXUIElementIsAttributeSettable(node, kAXSelectedAttribute as CFString, &settable) == .success && settable.boolValue
                }
            }, supported: supported,
            parent: { node in try? AX.onElement(node) { AX.axElement(AX.copy(node, kAXParentAttribute as String)) } },
            checkpoint: RequestRuntime.check)
    }

    static func prepare(_ element: AXUIElement?, bundle: String, delivery: NativeClickFocusPolicy.Delivery,
                        heldKey: Bool, webShaped: () throws -> Bool) throws -> CGEventFlags {
        let app = try AppResolver.require(bundle)
        let controller = SyntheticFocusSessions.clickController(app: app)
        let flags = try NativeClickFocusPolicy.prepare(delivery, focused: controller?.clickFocused, heldKey: heldKey,
            actualActive: {
                let application = AXUIElementCreateApplication(app.running.processIdentifier)
                let pid = try AccessibilityWindowSPI.actualPID(application)
                return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
            }, webShaped: webShaped,
            catalyst: {
                let application = AXUIElementCreateApplication(app.running.processIdentifier)
                return try AX.onElement(application) { AX.copy(application, "_AXExhibitsMacCatalystBehavior") as? Bool ?? false }
            }, maySelect: {
                guard let element else { return false }
                return try mayCauseSelection(element)
            }, menuButton: {
                guard let element else { return false }
                return try AX.onElement(element) { AX.string(element, kAXRoleAttribute as String) == "AXMenuButton" }
            },
            enforce: {
                // Keep the session's enforcer and restoration transaction;
                // ordinary background clicks must not activate NSRunningApplication.
                guard let controller else { return }
                let window = AXIndex.shared.snapshot(for: bundle)?.windowElement
                try controller.enforce(window: window)
            })
        return CGEventFlags(rawValue: flags)
    }
}
