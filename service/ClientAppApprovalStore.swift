import Foundation

/// Session state is updated before persistence, including failed writes. The
/// store uses a plain Data write and reloads only when the file date changes.
actor AppApprovalStore {
    struct PersistentApprovals: Codable, Equatable, Sendable {
        var approvedBundleIdentifiers = Set<String>()
    }

    private let storageURL: URL?
    private var sessionApprovedBundleIdentifiers = Set<String>()
    private(set) var persistentApprovals: PersistentApprovals
    private var persistentApprovalsModificationDate: Date?

    private static func modificationDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func load(_ url: URL?) -> PersistentApprovals {
        guard let url, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(PersistentApprovals.self, from: data) else { return .init() }
        return value
    }

    init(storageURL: URL?) {
        self.storageURL = storageURL
        persistentApprovals = Self.load(storageURL)
        persistentApprovalsModificationDate = Self.modificationDate(storageURL)
    }

    func isApproved(_ bundleIdentifier: String) -> Bool {
        if sessionApprovedBundleIdentifiers.contains(bundleIdentifier) { return true }
        refreshPersistentApprovals()
        return persistentApprovals.approvedBundleIdentifiers.contains(bundleIdentifier)
    }

    func refreshPersistentApprovals() {
        let modificationDate = Self.modificationDate(storageURL)
        guard modificationDate != persistentApprovalsModificationDate else { return }
        persistentApprovals = Self.load(storageURL)
        persistentApprovalsModificationDate = modificationDate
    }

    func approve(_ bundleIdentifier: String, permanently: Bool) throws {
        sessionApprovedBundleIdentifiers.insert(bundleIdentifier)
        guard permanently else { return }
        guard let storageURL else {
            throw MCPToolError.appApprovalPersistenceUnavailable(bundleIdentifier: bundleIdentifier)
        }
        persistentApprovals.approvedBundleIdentifiers.insert(bundleIdentifier)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(persistentApprovals).write(to: storageURL)
        persistentApprovalsModificationDate = Self.modificationDate(storageURL)
    }
}
