import Foundation
import CoreGraphics

struct ControllerLowerClickOptions: Sendable {
    let button: UInt32
    let count: Int
    let hold: Duration?
    let key: ControllerHeldClickKey
    let alwaysSimulate: Bool
}
struct ControllerHeldEventPair<Event> { let down: [Event]; let up: [Event] }
enum ControllerLowerClickFailure: Error, Equatable {
    case invalidCount
    case cannotCreateSource
    case cannotCreateEvent
    case cannotClickOffscreenElement
}

@MainActor protocol ControllerLowerClickBackend {
    associatedtype Node
    associatedtype Event
    var element: Node { get }
    var hasCursor: Bool { get }
    func actions() -> [String]
    func webShaped() -> Bool
    func webHit() async -> Bool
    func clickablePoint() async throws -> CGPoint?
    func target(at point: CGPoint) throws -> ControllerMouseEventTarget<Node>
    func prepareFocus(accessibility: Bool, element: Node?, web: Bool, held: Bool) async throws -> UInt64
    func pressCursor() async throws
    func perform(_ action: String) throws
    func mouseEvents(at point: CGPoint, target: ControllerMouseEventTarget<Node>, options: ControllerLowerClickOptions, flags: UInt64) throws -> [Event]
    func heldEvents(_ key: ControllerHeldClickKey) async throws -> ControllerHeldEventPair<Event>?
    func post(_ event: Event, pid: Int32)
    func deliverMouse(_ events: [Event], pid: Int32, hold: Duration?) async throws
}

/// Preserve reads before validation and distinct AX/mouse
/// semantics. In particular, AXPick/AXPress accepts zero/negative counts.
@MainActor struct ControllerLowerClick<Backend: ControllerLowerClickBackend> {
    let backend: Backend
    func click(_ options: ControllerLowerClickOptions) async throws {
        let actions = backend.actions()
        let action = actions.contains("AXPick") ? "AXPick" : (actions.contains("AXPress") ? "AXPress" : nil)
        let firstWeb = backend.webShaped()
        if options.count < 2, let action, options.button == 0, options.hold == nil,
           options.key.keyCode == nil, options.key.eventFlags == 0, !options.alwaysSimulate {
            // Sample this getter a second time only after all
            // AX eligibility gates, even if the first sample was false.
            let useMouse = backend.webShaped() ? await backend.webHit() : false
            if !useMouse {
                if backend.hasCursor { try await backend.pressCursor() }
                _ = try await backend.prepareFocus(accessibility: true, element: backend.element, web: firstWeb, held: false)
                try backend.perform(action)
                return
            }
        }
        guard let point = try await backend.clickablePoint() else { throw ControllerLowerClickFailure.cannotClickOffscreenElement }
        let target = try backend.target(at: point)
        let focusFlags = try await backend.prepareFocus(accessibility: false, element: target.element, web: firstWeb,
            held: options.key.keyCode != nil || options.key.eventFlags != 0)
        guard options.count > 0 else { throw ControllerLowerClickFailure.invalidCount }
        let events = try backend.mouseEvents(at: point, target: target, options: options, flags: options.key.eventFlags | focusFlags)
        let held = try await backend.heldEvents(options.key)
        if let held { for event in held.down { backend.post(event, pid: target.pid) } }
        // Posting is nonthrowing. Both success and sender failure restore the
        // fully prepared held-key release sequence without masking the error.
        defer { if let held { for event in held.up { backend.post(event, pid: target.pid) } } }
        try await backend.deliverMouse(events, pid: target.pid, hold: options.hold)
    }
}

/// The mouse-down cursor pre-delay can throw. Delays after
/// posting deliberately suppress errors (including cancellation), and no
/// interval follows the final event. The caller owns held-key restoration.
@MainActor struct ControllerClickEventSender<Event> {
    let isDown: (Event) -> Bool
    let post: (Event) -> Void
    let cursor: ((Bool) -> Void)?
    let wait: (Duration) async throws -> Void
    func send(_ events: [Event], hold: Duration?) async throws {
        for (index, event) in events.enumerated() {
            let down = isDown(event)
            if let cursor {
                cursor(down)
                if down { try await wait(.milliseconds(50)) }
            }
            post(event)
            if index != events.count - 1 {
                let interval: Duration = down ? max(hold ?? .milliseconds(50), .milliseconds(50)) : .milliseconds(50)
                try? await wait(interval)
            }
        }
    }
}

/// Builds events for a physical held key, or for flags only.
/// Held-click key parsing never supplies Unicode text to SAIVirtualKeyPress.
@MainActor struct ControllerHeldClickEventFactory<Source, Event> {
    let source: () -> Source?
    let currentFlags: () -> UInt64
    let flagsEvent: (Source, UInt64) -> Event?
    let keyboardEvent: (Source, UInt16, Bool, UInt64) -> Event?
    func make(_ key: ControllerHeldClickKey) throws -> ControllerHeldEventPair<Event>? {
        guard key.keyCode != nil || key.eventFlags != 0 else { return nil }
        guard let source = source() else { throw ControllerLowerClickFailure.cannotCreateSource }
        let previous = currentFlags()
        var down: [Event] = [], up: [Event] = []
        func flags(_ value: UInt64) throws -> Event {
            guard let event = flagsEvent(source, value) else { throw ControllerLowerClickFailure.cannotCreateEvent }
            return event
        }
        if let code = key.keyCode {
            let changed = previous & 0x1e0000 != key.eventFlags
            if changed { down.append(try flags(key.eventFlags)) }
            guard let press = keyboardEvent(source, code, true, key.eventFlags) else { throw ControllerLowerClickFailure.cannotCreateEvent }
            down.append(press)
            guard let release = keyboardEvent(source, code, false, key.eventFlags) else { throw ControllerLowerClickFailure.cannotCreateEvent }
            up.append(release)
            if changed { up.append(try flags(previous)) }
        } else {
            // Modifier-only holding always constructs both flagsChanged events,
            // including when the requested/current flags already match.
            down.append(try flags(key.eventFlags)); up.append(try flags(previous))
        }
        return .init(down: down, up: up)
    }
}

@MainActor struct ControllerClickFocusPreparation<Node> {
    let focused: () -> Bool?
    let actualActive: () throws -> Bool
    let catalyst: () -> Bool
    let maySelect: (Node?) -> Bool
    let menuButton: (Node?) -> Bool
    let enforce: () async throws -> Void
    func prepare(accessibility: Bool, element: Node?, web: Bool, held: Bool) async throws -> UInt64 {
        guard let focused = focused() else {
            let active = try actualActive()
            return !accessibility && !active ? 0x100000 : 0
        }
        if focused { return 0 }
        if accessibility {
            if catalyst(), maySelect(element) || menuButton(element) { try await enforce() }
            return 0
        }
        if held || web || maySelect(element) { try await enforce(); return 0 }
        if catalyst(), maySelect(element) || menuButton(element) { try await enforce(); return 0 }
        return 0x100000
    }
}

// Cursor press sequencing is shared with ControllerApprovedCursor in C109.
