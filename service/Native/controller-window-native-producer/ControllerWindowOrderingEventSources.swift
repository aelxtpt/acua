/// Native event sources for the staged C87 controller ordering algorithm.
/// Producer injection permits C ABI verification without native subscriptions.
enum ControllerWindowOrderingEventSources<Application: Sendable, Window: Sendable> {
    typealias Ordering = ControllerWindowOrdering<Application, Window>

    static func events(windowIDs: [UInt32], buffer: Int, producer: ControllerWindowNativeProducer) -> Ordering.Source {
        let pair = AsyncStream<Ordering.Event>.makeStream(bufferingPolicy: .bufferingNewest(buffer))
        let continuation = pair.continuation
        let observation = producer.observe(windowIDs: windowIDs, events: [.didChangeOrder]) { window, _ in
            _ = continuation.yield(.init(windowID: window.id, ownerPID: window.ownerPID))
        }
        return .init(events: pair.stream, lease: observation)
    }

    static func workspace(windowIDs: [UInt32], producer: ControllerWindowNativeProducer,
                          added: @escaping @Sendable () -> Void) -> any ControllerWindowOrderingLease {
        // Mark the flag for any delivered callback. No second filter.
        producer.observe(windowIDs: windowIDs, events: [.workspaceAddWindow]) { _, _ in added() }
    }
}
