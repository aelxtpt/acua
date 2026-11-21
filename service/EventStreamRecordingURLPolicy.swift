import Foundation

// Values are permission, not blocked status. Shared keys contain only
// the normalized URL.
final class ComputerUseURLBlocklistCache: @unchecked Sendable {
    static let shared = ComputerUseURLBlocklistCache()
    private struct Entry { let isAllowed: Bool; let expiresAt: Date }
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func isAllowed(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard now() < entry.expiresAt else { entries.removeValue(forKey: key); return nil }
        return entry.isAllowed
    }
    func store(isAllowed: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = Entry(isAllowed: isAllowed, expiresAt: now().addingTimeInterval(3600))
    }
}

@MainActor final class EventStreamRecordingURLPolicy {
    private let cache: ComputerUseURLBlocklistCache?
    private let checkPermission: (URL) async throws -> Bool
    private let onError: (Error) -> Void

    /// Blocks the domains in `[privacy] blocked_domains` of `~/.acua/config.toml`.
    /// The local list is read on every check and not cached, so a newly blocked
    /// domain applies to the next record or screenshot. An unreadable file blocks
    /// every site until it is fixed.
    static func local() -> EventStreamRecordingURLPolicy {
        .init(cache: nil, checkPermission: { url in
            guard let privacy = AcuaSettings.privacyFailingClosed() else { return false }
            guard let host = url.host else { return true }
            return !privacy.blocks(host: host)
        })
    }

    // Protocol-level injection retains throwing checkers and the outer default
    // semantics.
    init(cache: ComputerUseURLBlocklistCache?, checkPermission: @escaping (URL) async throws -> Bool,
         onError: @escaping (Error) -> Void = {
             FileHandle.standardError.write(Data("URL policy lookup failed: \(String(reflecting: $0))\n".utf8))
         }) {
        self.cache = cache; self.checkPermission = checkPermission; self.onError = onError
    }
    func isURLBlocked(_ url: URL, defaultOnError: Bool = false) async -> Bool {
        guard url.host != nil, url.scheme == "http" || url.scheme == "https" else { return false }
        let key = EventStreamURLPolicyRecordFilter.normalizedURLString(url)
        if let allowed = cache?.isAllowed(forKey: key) { return !allowed }
        do {
            let allowed = try await checkPermission(url)
            cache?.store(isAllowed: allowed, forKey: key)
            return !allowed
        } catch {
            onError(error)
            return defaultOnError
        }
    }
    func makeRecordFilter(resolver: EventStreamApplicationResolver) -> EventStreamURLPolicyRecordFilter {
        .init(isURLBlocked: { [self] in await isURLBlocked($0) }, resolver: resolver)
    }
}
