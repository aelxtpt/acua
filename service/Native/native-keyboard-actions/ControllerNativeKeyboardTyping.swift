import CoreGraphics
import Foundation

enum ControllerNativeKeyboardTyping {
    typealias Event = ControllerFocusNativeEvent
    struct Source: @unchecked Sendable { let value: CGEventSource }
    struct Environment: Sendable {
        let source: @Sendable () -> Source?
        let translate: @MainActor @Sendable (String) -> [ControllerKeyboardStroke]?
        let events: @Sendable (Source, [ControllerKeyboardStroke]) throws -> [Event]
        static var native: Self {
            .init(source: { CGEventSource(stateID: .hidSystemState).map { Source(value: $0) } },
                translate: { ControllerNativeKeyboardTextTranslation.translate($0) }, events: { source, strokes in
                    let native = ControllerNativeKeyboardEvents.factory()
                    return try ControllerKeyboardEventFactory(source: { source.value }, currentFlags: native.currentFlags,
                        flagsEvent: native.flagsEvent, keyboardEvent: native.keyboardEvent).make(strokes)
                })
        }
    }
    nonisolated static func make(_ text: String, environment: Environment = .native) async throws -> [Event] {
        // Create the source before hopping to the MainActor for TIS.
        guard let source = environment.source() else { throw ControllerSynthesizedEventError.failedToCreateSource }
        guard let strokes = await environment.translate(text) else { throw ControllerSynthesizedEventError.failedToTranslateKeyCodes }
        return try environment.events(source, strokes)
    }
}

extension ControllerNativeKeyboardEvents {
    nonisolated static func makeHolding(_ strokes: [ControllerKeyboardStroke]) async throws -> ControllerKeyboardHeldEvents<Event> {
        try factory().makeHolding(strokes)
    }
    nonisolated static func send(_ events: [Event], to pid: Int32, delay: Duration?) async throws {
        guard let delay else { await send(events, to: pid); return }
        let clock = ContinuousClock()
        try await ControllerKeyboardDelayedSender<Event>(timestamp: { DispatchTime.now().uptimeNanoseconds },
            setTimestamp: { $0.event.timestamp = $1 }, post: { $0.event.postToPid($1) },
            wait: { try await clock.sleep(until: clock.now.advanced(by: $0), tolerance: nil) })
            .send(events, to: pid, delay: delay)
    }
}
