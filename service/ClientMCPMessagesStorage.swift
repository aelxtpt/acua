import Foundation

struct ClientMCPMessagesStorage: Equatable, Sendable {
    let readDecisions: URL?
    let sendApprovals: URL?

    init(containerURL: URL?) {
        let directory = containerURL?.appendingPathComponent("Library/Application Support/Software", isDirectory: true)
        readDecisions = directory?.appendingPathComponent("MessagesReadDecisions.json", isDirectory: false)
        sendApprovals = directory?.appendingPathComponent("MessagesSendApprovals.json", isDirectory: false)
    }

    static func native(bundle: Bundle = .main, fileManager: FileManager = .default) -> Self {
        // The signed application group is package-specific. An
        // unavailable container produces nil decision URLs.
        let identifier = bundle.object(forInfoDictionaryKey: "CUAApplicationGroupIdentifier") as? String
        return .init(containerURL: identifier.flatMap { fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) })
    }
}
