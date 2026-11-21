import Foundation

/// A request can reserve resources while encoding, then publish them only after
/// its entire reply frame was written. Failure retains/reverts the reservation.
final class ResponseDelivery {
    private struct Hook { let commit, abandon: () -> Void }
    private let lock = NSLock()
    private var hooks: [Hook] = []
    private var finished = false
    private static let key = "acua.responseDelivery"
    static func withCurrent<T>(_ delivery: ResponseDelivery, _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = delivery
        defer { Thread.current.threadDictionary[key] = previous }
        return try body()
    }
    @discardableResult static func reserve(commit: @escaping () -> Void, abandon: @escaping () -> Void) -> Bool {
        guard let current = Thread.current.threadDictionary[key] as? ResponseDelivery else { return false }
        current.lock.lock(); defer { current.lock.unlock() }
        guard !current.finished else { return false }
        current.hooks.append(Hook(commit: commit, abandon: abandon)); return true
    }
    func commit() { finish(sent: true) }
    func abandon() { finish(sent: false) }
    private func finish(sent: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let actions = hooks; hooks.removeAll(); lock.unlock()
        for action in actions { if sent { action.commit() } else { action.abandon() } }
    }
    deinit { abandon() }
}
