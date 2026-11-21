import Foundation
import os

enum MessagesMCPToolError: Error, CustomStringConvertible, Sendable {
    case unknownTool(String)
    case approvalPersistenceUnavailable(String)
    case invalidReadResponse
    case invalidReadApprovalResponse
    case readAccessBlockedBySettings
    case readApprovalDenied
    case readApprovalCanceled

    var description: String {
        switch self {
        case .unknownTool(let name): "Unknown tool: " + name
        case .approvalPersistenceUnavailable(let displayName):
            "Messages could not persist the approval permanently for \(displayName)."
        case .invalidReadResponse:
            "Messages returned an invalid read response. No content was returned. Do not ask the user to approve access or retry. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
        case .invalidReadApprovalResponse:
            "The read approval response was invalid. No content was returned. Do not ask the user to approve access or retry. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
        case .readAccessBlockedBySettings:
            "Read access to this chat is blocked by the “Never allow” setting. No content was returned. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
        case .readApprovalDenied:
            "Read access was not approved. No content was returned. If the task's current approval_policy is confirmed to be never, explain, without naming the internal policy value, that the task's approval settings may have blocked the read confirmation, and suggest switching the task to Ask for approval or Approve for me before retrying. Otherwise, do not suggest changing approval settings or ask the user to approve access or retry. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
        case .readApprovalCanceled:
            "Content was not returned because the read approval was canceled. Do not ask the user to approve access or retry. Do not fall back to Computer Use or other tools to access the withheld content unless the user explicitly requests that alternative."
        }
    }
}

private enum MessagesApprovalFile {
    static func modificationDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
    static func load<T: Decodable>(_ type: T.Type, from url: URL?, fallback: T) -> T {
        guard let url, let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(type, from: data) else { return fallback }
        return value
    }
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// Remembered choices are kept on disk and session approvals in
/// memory. An actor serializes each reload/decision/write without suspension.
actor MessagesReadDecisionStore {
    enum ReadPolicy: Codable, Equatable, Sendable {
        case unknown(String), askPerChat, allowUnconfiguredChats, allowAllChats
        init(rawValue: String) {
            switch rawValue {
            case "askPerChat": self = .askPerChat
            case "allowUnconfiguredChats": self = .allowUnconfiguredChats
            case "allowAllChats": self = .allowAllChats
            default: self = .unknown(rawValue)
            }
        }
        var rawValue: String {
            switch self {
            case .unknown(let value): value
            case .askPerChat: "askPerChat"
            case .allowUnconfiguredChats: "allowUnconfiguredChats"
            case .allowAllChats: "allowAllChats"
            }
        }
        init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
    struct ChatDecision: Codable, Equatable, Sendable {
        enum Decision: Codable, Equatable, Sendable {
            case unknown(String), alwaysAllow, alwaysDeny, ask
            init(rawValue: String) {
                switch rawValue {
                case "alwaysAllow": self = .alwaysAllow
                case "alwaysDeny": self = .alwaysDeny
                case "ask": self = .ask
                default: self = .unknown(rawValue)
                }
            }
            var rawValue: String {
                switch self {
                case .unknown(let value): value
                case .alwaysAllow: "alwaysAllow"
                case .alwaysDeny: "alwaysDeny"
                case .ask: "ask"
                }
            }
            init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }
        var displayName: String
        var decision: Decision
    }
    struct PersistentDecisions: Codable, Equatable, Sendable {
        var readAccessPolicy: ReadPolicy
        var chats: [String: ChatDecision]
        init(readAccessPolicy: ReadPolicy = .askPerChat, chats: [String: ChatDecision] = [:]) {
            self.readAccessPolicy = readAccessPolicy
            self.chats = chats
        }
        enum CodingKeys: String, CodingKey { case readAccessPolicy, chats }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            readAccessPolicy = try container.decodeIfPresent(ReadPolicy.self, forKey: .readAccessPolicy) ?? .askPerChat
            chats = try container.decode([String: ChatDecision].self, forKey: .chats)
        }
    }
    enum Resolution: UInt8, Sendable { case allow = 0, deny = 1, ask = 2 }

    private let storageURL: URL?
    private var sessionApprovedChats = Set<String>()
    private(set) var persistentDecisions: PersistentDecisions
    private var persistentDecisionsModificationDate: Date?
    private let onRenameFailure: @Sendable (any Error) -> Void

    init(storageURL: URL?, onRenameFailure: @escaping @Sendable (any Error) -> Void = { error in
        Logger(subsystem: "com.aex.computeruse.client", category: "MessagesReadDecisionStore")
            .error("log[31dfdd8c15ba64d4a8fd] [0]=\(String(describing: error as NSError))")
    }) {
        self.storageURL = storageURL
        self.onRenameFailure = onRenameFailure
        persistentDecisions = MessagesApprovalFile.load(PersistentDecisions.self, from: storageURL, fallback: .init())
        persistentDecisionsModificationDate = MessagesApprovalFile.modificationDate(storageURL)
    }

    private func reloadIfChanged() {
        let modified = MessagesApprovalFile.modificationDate(storageURL)
        guard modified != persistentDecisionsModificationDate else { return }
        persistentDecisions = MessagesApprovalFile.load(PersistentDecisions.self, from: storageURL, fallback: .init())
        persistentDecisionsModificationDate = modified
    }

    func resolve(chatGUID: String, displayName: String) -> Resolution {
        reloadIfChanged()
        if persistentDecisions.readAccessPolicy.rawValue == "allowAllChats" { return .allow }
        if let configured = persistentDecisions.chats[chatGUID] {
            switch configured.decision {
            case .alwaysAllow, .alwaysDeny:
                if configured.displayName != displayName {
                    do { try persist(chatGUID: chatGUID, displayName: displayName, decision: configured.decision) }
                    catch { onRenameFailure(error) }
                }
                return configured.decision == .alwaysAllow ? .allow : .deny
            case .ask, .unknown: break
            }
        } else if persistentDecisions.readAccessPolicy.rawValue == "allowUnconfiguredChats" { return .allow }
        return sessionApprovedChats.contains(chatGUID) ? .allow : .ask
    }

    func approveForSession(chatGUID: String) { sessionApprovedChats.insert(chatGUID) }

    func persist(chatGUID: String, displayName: String, decision: ChatDecision.Decision) throws {
        guard let storageURL else { throw MessagesMCPToolError.approvalPersistenceUnavailable(displayName) }
        reloadIfChanged()
        var next = persistentDecisions
        next.chats[chatGUID] = .init(displayName: displayName, decision: decision)
        try MessagesApprovalFile.save(next, to: storageURL)
        persistentDecisions = next
        persistentDecisionsModificationDate = MessagesApprovalFile.modificationDate(storageURL)
    }
}

actor MessagesSendApprovalStore {
    struct PersistentApprovals: Codable, Equatable, Sendable {
        var allowAllChats: Bool
        var approvedChats: [String: String]
        init(allowAllChats: Bool = false, approvedChats: [String: String] = [:]) {
            self.allowAllChats = allowAllChats
            self.approvedChats = approvedChats
        }
        enum CodingKeys: String, CodingKey { case allowAllChats, approvedChats }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            allowAllChats = try container.decodeIfPresent(Bool.self, forKey: .allowAllChats) ?? false
            approvedChats = try container.decode([String: String].self, forKey: .approvedChats)
        }
    }
    private let storageURL: URL?
    private(set) var persistentApprovals: PersistentApprovals
    private var persistentApprovalsModificationDate: Date?
    private let onRenameFailure: @Sendable (any Error) -> Void

    init(storageURL: URL?, onRenameFailure: @escaping @Sendable (any Error) -> Void = { error in
        Logger(subsystem: "com.aex.computeruse.client", category: "MessagesSendApprovalStore")
            .error("log[4c64b1b7767f1a54ea68] [0]=\(String(describing: error as NSError))")
    }) {
        self.storageURL = storageURL
        self.onRenameFailure = onRenameFailure
        persistentApprovals = MessagesApprovalFile.load(PersistentApprovals.self, from: storageURL, fallback: .init())
        persistentApprovalsModificationDate = MessagesApprovalFile.modificationDate(storageURL)
    }

    private func reloadIfChanged() {
        let modified = MessagesApprovalFile.modificationDate(storageURL)
        guard modified != persistentApprovalsModificationDate else { return }
        persistentApprovals = MessagesApprovalFile.load(PersistentApprovals.self, from: storageURL, fallback: .init())
        persistentApprovalsModificationDate = modified
    }

    func requiresApproval(chatGUID: String?, displayName: String) -> Bool {
        reloadIfChanged()
        if persistentApprovals.allowAllChats { return false }
        guard let chatGUID, let configured = persistentApprovals.approvedChats[chatGUID] else { return true }
        if configured != displayName {
            do { try persist(chatGUID: chatGUID, displayName: displayName) }
            catch { onRenameFailure(error) }
        }
        return false
    }

    func persist(chatGUID: String, displayName: String) throws {
        guard let storageURL else { throw MessagesMCPToolError.approvalPersistenceUnavailable(displayName) }
        reloadIfChanged()
        var next = persistentApprovals
        next.approvedChats[chatGUID] = displayName
        try MessagesApprovalFile.save(next, to: storageURL)
        persistentApprovals = next
        persistentApprovalsModificationDate = MessagesApprovalFile.modificationDate(storageURL)
    }
}
