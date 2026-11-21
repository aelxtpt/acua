import Foundation

enum ControllerKeyboardActionKind: UInt8, Sendable { case type, press, hold }
struct ControllerKeyboardActionParameters: Sendable {
    let kind: ControllerKeyboardActionKind
    let text: String?
    let duration: Duration?
    let waitForUIToSettle: Bool
    let returnAppSnapshot: Bool
}
enum ControllerKeyboardActionFailure: Error, Equatable { case missingText, missingDuration }

@MainActor protocol ControllerKeyboardActionBackend {
    associatedtype Tree: Sendable
    associatedtype Target: Sendable
    associatedtype Event: Sendable
    associatedtype Cache: Sendable
    associatedtype AppSnapshot: Sendable
    func ensureFocusEnforcer()
    var believesFocused: Bool? { get }
    var lastTree: Tree? { get }
    func captureForFocus() async throws -> Tree
    func enforceFocus(in tree: Tree) async throws
    func keyboardTarget() throws -> Target
    var typingDelay: Duration { get }
    func typeEvents(_ text: String) async throws -> [Event]
    func pressEvents(_ text: String) async throws -> [Event]
    func holdEvents(_ text: String) async throws -> ControllerKeyboardHeldEvents<Event>
    func send(_ events: [Event], to target: Target, delay: Duration?) async throws
    func hold(for duration: Duration) async throws
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle() async throws -> Cache?
    func capture(cache: Cache?) async throws -> AppSnapshot
}

@MainActor struct ControllerKeyboardOperation<Backend: ControllerKeyboardActionBackend> {
    let backend: Backend
    func perform(_ parameters: ControllerKeyboardActionParameters) async throws -> Backend.AppSnapshot? {
        backend.ensureFocusEnforcer()
        if backend.believesFocused != nil {
            let tree: Backend.Tree
            if let previous = backend.lastTree { tree = previous }
            else { tree = try await backend.captureForFocus() }
            try await backend.enforceFocus(in: tree)
        }
        let target = try backend.keyboardTarget()
        defer { withExtendedLifetime(target) {} }
        guard let text = parameters.text else { throw ControllerKeyboardActionFailure.missingText }
        switch parameters.kind {
        case .type:
            let events = try await backend.typeEvents(text)
            try await backend.send(events, to: target, delay: backend.typingDelay)
        case .press:
            let events = try await backend.pressEvents(text)
            try await backend.send(events, to: target, delay: nil)
        case .hold:
            guard let duration = parameters.duration else { throw ControllerKeyboardActionFailure.missingDuration }
            let events = try await backend.holdEvents(text)
            // A down-send failure exits without attempting keyUp.
            try await backend.send(events.down, to: target, delay: nil)
            do {
                try await backend.hold(for: duration)
                try await backend.send(events.up, to: target, delay: nil)
            } catch {
                // Retry keyUp, but rethrow the first sleep/up error even when
                // the cleanup send itself also fails.
                try? await backend.send(events.up, to: target, delay: nil)
                throw error
            }
        }
        guard parameters.returnAppSnapshot else { backend.needsUISettleBeforeAppSnapshot = true; return nil }
        if parameters.waitForUIToSettle {
            backend.needsUISettleBeforeAppSnapshot = false
            let cache = try await backend.settle()
            return try await backend.capture(cache: cache)
        }
        // The direct-capture branch does not change the settle flag.
        return try await backend.capture(cache: nil)
    }
}

struct ControllerKeyboardDelayedSender<Event: Sendable>: Sendable {
    let timestamp: @Sendable () -> UInt64
    let setTimestamp: @Sendable (Event, UInt64) -> Void
    let post: @Sendable (Event, Int32) -> Void
    let wait: @Sendable (Duration) async throws -> Void
    func send(_ events: [Event], to pid: Int32, delay: Duration) async throws {
        for event in events {
            setTimestamp(event, timestamp())
            post(event, pid)
            // Sleep after every posted event, including the last one.
            try await wait(delay)
        }
    }
}
