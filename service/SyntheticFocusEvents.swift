import AppKit
import ApplicationServices
import Darwin

// Layout of the synthetic AppKit focus activation/deactivation events.
// These packets change the receiver's AppKit activation state; they must be
// paired with the focus controller, never posted to a global HID event tap.
enum SyntheticFocusEvents {
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(image, "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    static func activation(windowID: CGWindowID = 0, frame: CGRect? = nil,
                           activationPoint: CGPoint? = nil) throws -> [CGEvent] {
        let activate = try packet(type: 13, subtype: 1, windowID: windowID,
                                  flags: windowID == 0 ? 0 : 786_432)
        guard windowID != 0, let frame, let point = activationPoint,
              ClickableGeometry.valid(frame), point.x.isFinite, point.y.isFinite else { return [activate] }
        guard let setWindowLocation else {
            throw ServiceError(.accessibilityError, "Synthetic focus window-location API is unavailable")
        }
        var result = [activate]
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: Int(windowID), context: nil,
                eventNumber: index + 1, clickCount: 1, pressure: 1)?.cgEvent else {
                throw ServiceError(.accessibilityError, "Could not create synthetic focus event")
            }
            event.flags = []
            event.location = point
            event.setIntegerValueField(.mouseEventNumber, value: 0)
            event.setIntegerValueField(.mouseEventClickState, value: 3)
            for field in [UInt32(91), 92] {
                event.setIntegerValueField(CGEventField(rawValue: field)!, value: Int64(windowID))
            }
            setWindowLocation(event, CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
            result.append(event)
        }
        return result
    }

    static func keyFocusReturned() throws -> [CGEvent] {
        [try packet(type: 21, subtype: Int16(bitPattern: 0x8000))]
    }

    // Create, timestamp and directly post each process notice
    // before constructing the next. These are not input/action events.
    static func repairHostedFocus(to pid: pid_t) throws {
        for subtype: UInt16 in [0x4000, 0x8000] {
            let event = try packet(type: 21, subtype: Int16(bitPattern: subtype))
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            event.postToPid(pid)
        }
    }
    static func deactivation() throws -> [CGEvent] { [try packet(type: 13, subtype: 2)] }

    private static func packet(type: UInt, subtype: Int16, windowID: CGWindowID = 0,
                               flags: UInt = 0) throws -> CGEvent {
        guard let eventType = NSEvent.EventType(rawValue: type),
              let event = NSEvent.otherEvent(with: eventType, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
                windowNumber: Int(windowID), context: nil, subtype: subtype, data1: 0, data2: 0)?.cgEvent else {
            throw ServiceError(.accessibilityError, "Could not create synthetic activation packet")
        }
        return event
    }

    static func send(_ events: [CGEvent], to pid: pid_t) {
        for event in events {
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            UserInteraction.markSynthesized(event)
            event.postToPid(pid)
        }
    }
}

struct SyntheticFocusState: Equatable {
    var believesActive: Bool
    var believesFocused: Bool
    var actuallyActive: Bool

    // Only the matching type/subtype transitions are recognized.
    mutating func observe(type: UInt32, subtype: Int64) {
        let active: Bool
        if type == 20 || (type == 13 && subtype == 1) { active = true }
        else if type == 19 || (type == 13 && subtype == 2) { active = false }
        else { return }
        believesActive = active
        believesFocused = active
    }
    var needsActivation: Bool { !believesActive && !believesFocused }
    var needsKeyFocusReturn: Bool { believesActive && !believesFocused }
    var needsDeactivation: Bool { believesActive && !actuallyActive }
}

