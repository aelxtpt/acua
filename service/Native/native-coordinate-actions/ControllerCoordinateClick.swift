import Foundation

struct ControllerCoordinateClickParameters: Sendable {
    var position: ControllerScaledCursorPosition? = nil
    var destination: ControllerScaledCursorPosition? = nil
    var button: UInt32 = 0
    var count = 1
    var hold: Duration? = nil
    var key: String? = nil
    var returnAppSnapshot = true
    var animateCursor = true
}
enum ControllerCoordinateClickFailure: Error, Equatable {
    case unsupportedMenuAction
    case cannotPressMenuItem
}
@MainActor protocol ControllerCoordinateClickBackend {
    associatedtype Target
    associatedtype Cache
    associatedtype AppSnapshot
    var position: ControllerScaledCursorPosition { get nonmutating set }
    func global(_ position: ControllerScaledCursorPosition) -> CGPoint
    func target(at point: CGPoint) throws -> Target
    func requireAllowed(_ target: Target) throws
    func cursorWindowID(_ target: Target) throws -> UInt32
    func prepareCursor(at point: CGPoint, above windowID: UInt32, drag: Bool, animated: Bool) async
    func isMenu(_ target: Target) -> Bool
    func movePhysical(at point: CGPoint, target: Target) async throws
    func pressMenu(_ target: Target) throws
    func click(_ target: Target, destination: CGPoint?, options: ControllerCoordinateClickParameters,
               key: ControllerHeldClickKey) async throws
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle() async throws -> Cache?
    func capture(cache: Cache?) async throws -> AppSnapshot
}

/// The drag destination is mapped before the held key is parsed and before
/// replacing the start position. Awaited cursor placement can change geometry;
/// every later point read deliberately uses the current owner state.
@MainActor struct ControllerCoordinateClick<Backend: ControllerCoordinateClickBackend> {
    let backend: Backend
    func click(_ options: ControllerCoordinateClickParameters) async throws -> Backend.AppSnapshot? {
        let destination = options.destination.map(backend.global)
        let key = try options.key.map(ControllerHeldClickKey.parse) ?? .none
        backend.position = options.position ?? .zero
        let target = try backend.target(at: backend.global(backend.position))
        try backend.requireAllowed(target)
        let windowID = try backend.cursorWindowID(target)
        await backend.prepareCursor(at: backend.global(backend.position), above: windowID,
                                    drag: destination != nil, animated: options.animateCursor)
        let menu = backend.isMenu(target)
        if !menu { try await backend.movePhysical(at: backend.global(backend.position), target: target) }
        if menu {
            guard options.hold == nil, key.keyCode == nil, key.eventFlags == 0 else {
                throw ControllerCoordinateClickFailure.unsupportedMenuAction
            }
            // Menu identity comes from the selected registry entry. A drag
            // destination, button or count does not disqualify this branch.
            try backend.pressMenu(target)
        } else {
            try await backend.click(target, destination: destination, options: options, key: key)
        }
        guard options.returnAppSnapshot else { backend.needsUISettleBeforeAppSnapshot = true; return nil }
        backend.needsUISettleBeforeAppSnapshot = false
        let cache = try await backend.settle()
        return try await backend.capture(cache: cache)
    }
}

/// Only the cursor pre-down wait propagates errors. Post-event waits
/// suppress errors and there is no final wait or synthetic release-on-error.
@MainActor struct ControllerCoordinateClickSender<Event> {
    let isDown: (Event) -> Bool
    let post: (Event) -> Void
    let cursor: ((Bool) -> Void)?
    let wait: (Duration) async throws -> Void
    func send(_ events: [Event], hold: Duration?, interval: Duration?) async throws {
        for (index, event) in events.enumerated() {
            let down = isDown(event)
            if let cursor {
                cursor(down)
                if down { try await wait(.milliseconds(50)) }
            }
            post(event)
            if let delay = NativeMouseClick.delay(mouseDown: down, isLast: index == events.count - 1,
                                                  hold: hold, interval: interval) {
                try? await wait(delay)
            }
        }
    }
}
