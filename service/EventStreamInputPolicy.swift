import AppKit
import CoreGraphics

// Recorder input policy. This is input observation, not a complete
// EventStream record: AX, buffers and capture policy follow it.
enum EventStreamInputPolicy {
    static let eventTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown]
    static let eventMask: CGEventMask = eventTypes.reduce(0) { $0 | (1 << $1.rawValue) }

    static func modifiers(_ flags: CGEventFlags) -> [String] {
        let values: [(CGEventFlags, String)] = [(.maskCommand, "command"),
            (.maskControl, "control"), (.maskAlternate, "option"),
            (.maskShift, "shift"), (.maskSecondaryFn, "function")]
        return values.compactMap { flags.contains($0.0) ? $0.1 : nil }
    }

    static func button(_ type: CGEventType) -> String? {
        switch type {
        case .leftMouseDown, .leftMouseUp: return "left"
        case .rightMouseDown, .rightMouseUp: return "right"
        case .otherMouseDown, .otherMouseUp: return "other"
        default: return nil
        }
    }

    // Movement is measured between down/up; dragged events are
    // deliberately absent from the tap mask. Equality at six points is a drag.
    static func isDrag(button: String?, originButton: String?, origin: CGPoint?, destination: CGPoint) -> Bool {
        guard button == originButton, let origin else { return false }
        return hypot(destination.x - origin.x, destination.y - origin.y) >= 6
    }

    static func mouseKind(button: String?, flags: CGEventFlags, isDrag: Bool) -> EventStreamEventKind {
        if isDrag { return .mouseDrag }
        if button == "right" || flags.contains(.maskControl) { return .mouseContextMenu }
        return .mouseClick
    }

    static func isTextInput(keyCode: UInt16, characters: String, flags: CGEventFlags) -> Bool {
        guard keyCode != 63, keyCode != 179, !characters.isEmpty,
              flags.intersection([.maskCommand, .maskControl]).isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            $0.value > 0x1F && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    static func keyEquivalent(keyCode: UInt16, charactersIgnoringModifiers: String) -> String {
        switch keyCode {
        case 36, 76: return "return"
        case 48: return "tab"
        case 51: return "delete"
        case 53: return "escape"
        case 63: return "function"
        case 117: return "forward_delete"
        case 123: return "left_arrow"
        case 124: return "right_arrow"
        case 125: return "down_arrow"
        case 126: return "up_arrow"
        case 179: return "globe"
        default: return charactersIgnoringModifiers
        }
    }

    struct Target: Equatable {
        var processIdentifier: Int32?
        var windowID: UInt32?
    }

    static func target(windowID: UInt32?, targetPID: Int64, windowOwner: (UInt32) -> Int32?) -> Target {
        let window = windowID.flatMap { $0 == 0 ? nil : $0 }
        if let window, let owner = windowOwner(window) {
            return Target(processIdentifier: owner, windowID: window)
        }
        // Native field 40 is PID-sized. Reject an impossible
        // out-of-range observation instead of truncating it to an unrelated PID.
        let pid = Int32(exactly: targetPID).flatMap { $0 > 0 ? $0 : nil }
        return Target(processIdentifier: pid, windowID: window)
    }
}

struct EventStreamInputObservation {
    let type: CGEventType
    let location: CGPoint
    let flags: CGEventFlags
    let target: EventStreamInputPolicy.Target
    let clickCount: Int64
    let keyCode: UInt16?
    let characters: String
    let charactersIgnoringModifiers: String

    static func read(type: CGEventType, event: CGEvent,
                     windowOwner: (UInt32) -> Int32?) -> Self? {
        guard EventStreamInputPolicy.eventTypes.contains(type) else { return nil }
        let window = CGEventField(rawValue: 51).flatMap {
            UInt32(exactly: event.getIntegerValueField($0))
        }
        let target = EventStreamInputPolicy.target(windowID: window,
            targetPID: event.getIntegerValueField(.eventTargetUnixProcessID), windowOwner: windowOwner)
        let key = type == .keyDown ? NSEvent(cgEvent: event) : nil
        let code = type == .keyDown ? UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) : nil
        return Self(type: type, location: event.location, flags: event.flags, target: target,
            clickCount: event.getIntegerValueField(.mouseEventClickState), keyCode: code,
            characters: key?.characters ?? "",
            charactersIgnoringModifiers: key?.charactersIgnoringModifiers ?? key?.characters ?? "")
    }
}
