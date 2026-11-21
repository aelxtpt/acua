import Foundation
// Test-only substitute for the asynchronous native URL policy dependency.
// No network, account, preference or service calls are performed.
enum ActionAppSnapshotURLPolicy {
    static func check(_ text: String?, for app: ResolvedApp) throws {
        let pending = PendingResult<Bool>(discard: { _ in })
        let task = Task { @MainActor in pending.complete(.success(true)) }
        defer { task.cancel(); pending.abandon() }
        try RequestRuntime.wait(for: pending.signal, maximumSeconds: 0.25)
        _ = try pending.take()
    }
}
