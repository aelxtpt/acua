import Foundation

extension ControllerNativeOwnerAssembly {
    enum Failure: Error { case unavailableWindowServer }
    /// The optional bridge provider starts as nil. The
    /// static references only copy/read it; no real mandatory cache is implied.
    /// Resolve symbols and construct shared owners here without starting taps.
    static func native(analytics: @escaping @Sendable (Owner.Analytics) -> Void,
                       orderingLog: @escaping @Sendable (Ordering.Log) -> Void,
                       hideCursor: @escaping @MainActor @Sendable (Cursor) async -> Void,
                       log: @escaping @Sendable (String, any Error) -> Void) throws -> Self {
        guard let windowServer = ControllerNativeWindowServer.resolve(), let producer = ControllerWindowNativeProducer.native() else {
            throw Failure.unavailableWindowServer
        }
        return .init(resources: .shared(lookup: { _ in nil }, windowServer: windowServer, log: log),
            producer: producer, attention: .resolve(), analytics: analytics, orderingLog: orderingLog, hideCursor: hideCursor)
    }
}
