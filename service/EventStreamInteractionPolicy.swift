import CoreGraphics

// Recorder's endpoint/shortcut policies.
enum EventStreamInteractionPolicy {
    static let textSelectionRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]
    static let interactiveRoles: Set<String> = ["AXButton", "AXCheckBox", "AXColorWell",
        "AXComboBox", "AXDateField", "AXDateTimeArea", "AXDisclosureTriangle",
        "AXDockItem", "AXIncrementor", "AXLink", "AXMenuBarItem", "AXMenuButton",
        "AXMenuItem", "AXPopUpButton", "AXRadioButton", "AXSlider"]

    static func omitMouse(kind: EventStreamEventKind, mouse: EventStreamMouseInteraction) -> Bool {
        if kind == .mouseClick && mouse.button == "left" && (mouse.clickCount ?? 0) >= 2,
           let role = mouse.target?.role, textSelectionRoles.contains(role) { return true }
        guard kind == .mouseDrag else { return false }
        if mouse.origin == mouse.destination { return true }
        guard let origin = mouse.origin, let destination = mouse.destination,
              let originRole = origin.element?.role, let destinationRole = destination.element?.role,
              textSelectionRoles.contains(originRole), textSelectionRoles.contains(destinationRole),
              let pid = origin.app?.processIdentifier, let otherPID = destination.app?.processIdentifier,
              pid == otherPID, let window = origin.window?.windowID,
              let otherWindow = destination.window?.windowID, window == otherWindow else { return false }
        return true
    }

    // This is eligibility, not a final suppression decision. The recorder
    // sends eligible records through the suppressed callback only when the AX
    // payload reports no change or no useful payload is available.
    static func suppressMouseWhenAXUnchanged(kind: EventStreamEventKind,
                                             mouse: EventStreamMouseInteraction) -> Bool {
        if kind == .mouseDrag || (kind == .mouseClick && (mouse.clickCount ?? 0) > 1) { return false }
        return !interactiveRoles.contains(mouse.target?.role ?? "")
    }

    struct KeyboardDecision: Equatable {
        let kind: EventStreamEventKind
        let capturesAX: Bool
    }

    // Captured role is from key-down; current role/character count are queried
    // after 250 ms only for Return in a captured text area.
    static func keyboard(keyCode: UInt16, flags: CGEventFlags, capturedRole: String?,
                         currentRole: String?, currentCharacterCount: Int?,
                         bundleIdentifier: String?) -> KeyboardDecision {
        let isReturn = keyCode == 36 || keyCode == 76
        var submit = isReturn
        if capturedRole == "AXTextArea" {
            if !isReturn {
                let captures = flags.contains(.maskCommand) || keyCode == 53 || keyCode == 179
                return .init(kind: .keyboardShortcut, capturesAX: captures)
            }
            submit = currentRole == "AXTextArea"
                && flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty
                && (currentCharacterCount == 0 ||
                    (currentCharacterCount == 1 && bundleIdentifier == "com.tinyspeck.slackmacgap"))
        }
        let editKey = [UInt16(36), 76, 48, 51, 53, 117].contains(keyCode)
        let captures = flags.contains(.maskCommand) || keyCode == 53 || keyCode == 179
            || (editKey && capturedRole != "AXTextArea" && capturedRole != "AXTextField")
            || submit
        return .init(kind: submit ? .keyboardSubmit : .keyboardShortcut, capturesAX: captures)
    }
}
