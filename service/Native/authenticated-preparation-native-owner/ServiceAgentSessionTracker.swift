import Foundation

/// Tracks which apps each agent session uses. Associations and expiry
/// changes share one lock; native side effects happen after releasing that lock.
final class ComputerUseSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var applications = [String: Set<String>]()
    private var endedTurnIDs = [String: Date]()
    @discardableResult func recordUse(_ bundle: String, threadID: String?) -> Bool {
        guard let threadID else { return false }
        // Empty session/bundle strings that are present are not filtered out.
        return lock.withLock {
            if let turnID, !turnID.isEmpty { latestTurnIDs[threadID] = turnID }
            return applications[threadID, default: []].insert(bundle).inserted
        }
    }
    func hasEnded(_ turnID: String, now: Date = .now) -> Bool {
        lock.withLock { endedTurnIDs[turnID].map { $0 > now } ?? false }
    }
    private func recordEndLocked(_ turnID: String?, now: Date) {
        guard let turnID, !turnID.isEmpty else { return }
        endedTurnIDs = endedTurnIDs.filter { $0.value > now }
        endedTurnIDs[turnID] = now.addingTimeInterval(300)
    }
    func recordEnd(_ turnID: String?, now: Date = .now) { lock.withLock { recordEndLocked(turnID, now: now) } }
    func end(threadID: String, turnID: String?, now: Date = .now) -> Set<String> {
        lock.withLock {
            recordEndLocked(turnID, now: now)
            let removed = applications.removeValue(forKey: threadID) ?? []
            return removed.filter { bundle in !applications.values.contains { $0.contains(bundle) } }
        }
    }
}
