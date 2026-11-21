import Foundation

struct ClientMCPAutomationStorage: Equatable, Sendable {
    let analyticsDirectory: URL?
    let appApprovals: URL?

    init(containerURL: URL?) {
        analyticsDirectory = containerURL?
            .appendingPathComponent("Library/Application Support/Software", isDirectory: true)
        appApprovals = analyticsDirectory?
            .appendingPathComponent("ComputerUseAppApprovals.json", isDirectory: false)
    }

    static func native(bundle: Bundle = .main, fileManager: FileManager = .default) -> Self {
        let identifier = bundle.object(forInfoDictionaryKey: "CUAApplicationGroupIdentifier") as? String
        return .init(containerURL: identifier.flatMap { fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) })
    }
}
