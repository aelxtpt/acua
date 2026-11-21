import Foundation

// Service startup resolves the optional app-group container once; the root
// resolver below only appends path components and performs no I/O.
enum EventStreamStorageConfiguration {
    enum Purpose { case recordAndReplay, timeline }
    static let applicationGroupInfoKey = "CUAApplicationGroupIdentifier"

    /// A signed distribution names its own team's group
    /// (`<team>.com.aex.computeruse`) in its Info.plist. A missing, empty or
    /// non-string value disables group storage, as for ad-hoc packages and
    /// raw executables.
    static func configuredApplicationGroupIdentifier(bundle: Bundle = .main) -> String? {
        guard let identifier = bundle.object(forInfoDictionaryKey: applicationGroupInfoKey) as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    static func nativeContainerURL(fileManager: FileManager = .default, bundle: Bundle = .main) -> URL? {
        configuredApplicationGroupIdentifier(bundle: bundle).flatMap {
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var containerURL: URL?
    }
    private static let state = State()

    static func configure(appGroupContainerURL: URL?) {
        state.lock.lock()
        state.containerURL = appGroupContainerURL
        state.lock.unlock()
    }

    static func configureNative(fileManager: FileManager = .default, bundle: Bundle = .main) {
        configure(appGroupContainerURL: nativeContainerURL(fileManager: fileManager, bundle: bundle))
    }

    static func rootDirectoryURL(for purpose: Purpose) -> URL? {
        state.lock.lock()
        let containerURL = state.containerURL
        state.lock.unlock()
        return containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("ComputerUse", isDirectory: true)
            .appendingPathComponent(purpose == .recordAndReplay ? "RecordAndReplay" : "Timeline", isDirectory: true)
    }
}
