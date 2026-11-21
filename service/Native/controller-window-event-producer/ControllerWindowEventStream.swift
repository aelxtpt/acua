/// Every iterator creates and retains its own observer. The
/// continuation yields without checking the YieldResult; no onTermination hook.
struct ControllerWindowEventStream<Window: Sendable>: AsyncSequence, Sendable {
    typealias Element = (Window, ControllerWindowServerEvent)
    let windowIDs: [UInt32]
    let events: [ControllerWindowServerEvent]
    let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
    let environment: ControllerWindowEventObserver<Window>.Environment

    struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: AsyncStream<Element>
        private var iterator: AsyncStream<Element>.Iterator
        private let observer: ControllerWindowEventObserver<Window>

        fileprivate init(_ source: ControllerWindowEventStream) {
            let pair = AsyncStream<Element>.makeStream(bufferingPolicy: source.bufferingPolicy)
            let continuation = pair.continuation
            stream = pair.stream
            iterator = pair.stream.makeAsyncIterator()
            observer = ControllerWindowEventObserver(windowIDs: source.windowIDs, events: source.events,
                environment: source.environment) { window, event in
                    _ = continuation.yield((window, event))
                }
        }

        mutating func next() async -> Element? {
            // Explicit lifetime prevents early subscription release across suspension.
            let element = await iterator.next()
            withExtendedLifetime((stream, observer)) {}
            return element
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(self) }
}
