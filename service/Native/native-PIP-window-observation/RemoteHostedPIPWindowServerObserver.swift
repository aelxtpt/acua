import CoreGraphics
import Foundation

// Short spellings alias cases of the complete event enum. The
// shared native dispatcher, rather than a second registry, owns raw decoding.
extension ControllerWindowServerEvent {
    static var terminated: Self { .isTerminated }
    static var resized: Self { .didResize }
    static var orderChanged: Self { .didChangeOrder }
    static var geometryChanged: Self { .geometryDidChange }
    static var workspaceAddedWindow: Self { .workspaceAddWindow }
}

final class RemoteHostedPIPWindowServerObserver: Sendable {
    typealias Event = ControllerWindowServerEvent
    private let registration: ControllerWindowNativeProducer.Observation

    /// The default events are [7,9,4] in that order, not a sorted set. The
    /// on-screen window ID reader supplies an ID snapshot for workspace
    /// observation; nil is this legacy convenience,
    /// never a wildcard subscription or a different callback payload layout.
    init?(windowIDs: [CGWindowID]?, events: [Event] = [.resized,.geometryChanged,.terminated],
          producer: ControllerWindowNativeProducer? = ControllerWindowNativeProducer.native(),
          onScreenWindowIDs: @Sendable () -> [UInt32] = { ControllerOnScreenWindowIDs.read() },
          onEvent: @escaping @Sendable (CGWindowID, Event) -> Void) {
        guard let producer else { return nil }
        let identifiers = windowIDs ?? onScreenWindowIDs()
        registration = producer.observe(windowIDs: identifiers, events: events) { window,event in
            // Forward the parsed live/seed descriptor. There is no extra
            // window/event membership or callback-length filter.
            onEvent(window.id,event)
        }
    }
}
