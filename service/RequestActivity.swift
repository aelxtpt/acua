import Foundation

/// Two independent, best-effort assertions owned by one authenticated request.
/// A failed acquisition does not fail the request or discard the other assertion.
final class RequestActivity {
    enum Kind: String, CaseIterable { case remoteUserActivity, displaySleepPrevention }
    struct Provider {
        var create: (Kind, inout UInt32) -> Int32
        var release: (UInt32) -> Int32
        var failed: (Kind, Int32) -> Void = { _, _ in }
    }
    final class Lease {
        private let lock = NSLock()
        private var assertions: [UInt32]
        private let release: (UInt32) -> Int32

        fileprivate init(_ assertions: [UInt32], release: @escaping (UInt32) -> Int32) {
            self.assertions = assertions
            self.release = release
        }
        func cancel() {
            // Detach before invoking providers: concurrent/reentrant cancellation
            // and deinitialization must never release an assertion a second time.
            let owned = lock.withLock {
                let owned = assertions
                assertions.removeAll()
                return owned
            }
            for assertion in owned.reversed() { _ = release(assertion) }
        }
        deinit { cancel() }
    }

    private let provider: Provider
    init(provider: Provider) { self.provider = provider }

    func begin(_ preparation: RequestPreparation) -> Lease? {
        guard preparation.holdsActivity else { return nil }
        var assertions = [UInt32]()
        for kind in Kind.allCases {
            var assertion: UInt32 = 0
            let status = provider.create(kind, &assertion)
            // Acquisition rejects both an error status and assertion ID 0.
            if status == 0 && assertion != 0 { assertions.append(assertion) }
            else { provider.failed(kind, status) }
        }
        return Lease(assertions, release: provider.release)
    }
}
