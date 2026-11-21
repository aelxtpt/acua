import AppKit
import ApplicationServices
import Carbon
import Contacts
import Foundation
import os

enum MessagesPermissionDecision: Sendable { case granted, pending, denied }

@MainActor final class MessagesPermissionGate {
    static let shared = MessagesPermissionGate()
    private nonisolated static let messagesBundleID = "com.apple.MobileSMS"
    private let contacts = CNContactStore()
    private var prompting = false

    func check() -> MessagesPermissionDecision {
        guard FileManager.default.isReadableFile(atPath: "/Library/Preferences/com.apple.TimeMachine.plist") else {
            return .denied
        }
        if prompting { return .pending }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined:
            prompting = true
            Task {
                defer { prompting = false }
                _ = try? await contacts.requestAccess(for: .contacts)
            }
            return .pending
        default: return .denied
        }

        let bundleID = Self.messagesBundleID
        let defaults = UserDefaults.standard
        var cached = defaults.dictionary(forKey: "AppleEventsPermissions") as? [String: Bool] ?? [:]
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            switch Self.automationStatus(askUser: false) {
            case noErr:
                if cached[bundleID] != true {
                    cached[bundleID] = true
                    defaults.set(cached, forKey: "AppleEventsPermissions")
                }
                return .granted
            case OSStatus(errAEEventWouldRequireUserConsent):
                clearAutomationGrant()
                prompting = true
                Task {
                    defer { prompting = false }
                    let status = await Task.detached { Self.automationStatus(askUser: true) }.value
                    if status == noErr {
                        var approvals = defaults.dictionary(forKey: "AppleEventsPermissions") as? [String: Bool] ?? [:]
                        approvals[bundleID] = true
                        defaults.set(approvals, forKey: "AppleEventsPermissions")
                    }
                }
                return .pending
            case OSStatus(errAEEventNotPermitted):
                clearAutomationGrant()
                return .denied
            case OSStatus(procNotFound): break
            default: return .denied
            }
        }
        return cached[bundleID] == true ? .granted : .denied
    }

    private func clearAutomationGrant() {
        let defaults = UserDefaults.standard
        var cached = defaults.dictionary(forKey: "AppleEventsPermissions") as? [String: Bool] ?? [:]
        if cached.removeValue(forKey: Self.messagesBundleID) != nil {
            defaults.set(cached, forKey: "AppleEventsPermissions")
        }
    }

    private nonisolated static func automationStatus(askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: messagesBundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askUser)
    }
}

enum MessagesIPC {
    private static let queue = AsyncSerialQueue()
    private static let sendPlans = MessagesSendPlans()

    static func readImage(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) }
    ) throws -> Any {
        try perform(request: request, route: .readImage, permission: permission) { (input: MessagesIPCReadImageRequest, access) in
            try executeImage(input, permission: access, database: database, contactName: contactName)
        }
    }

    static func readMessages(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) }
    ) throws -> Any {
        try perform(request: request, route: .readMessages, permission: permission) { (input: MessagesIPCReadMessagesRequest, access) in
            try requireAccess(access)
            do {
                return try MessagesReadPage.make(input, database: database, contactName: contactName)
            } catch let error as MessagesPaging.CursorError {
                throw ServiceError(.messagesInvalidRequest, error.message(tool: "read_messages"))
            } catch let error as MessagesReadValidationError {
                throw ServiceError(.messagesInvalidRequest, error.description)
            }
        }
    }

    static func findChats(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        aliases: @escaping @Sendable (String) throws -> [String] = { try contactAliases($0) },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) }
    ) throws -> Any {
        try perform(request: request, route: .findChats, permission: permission) { (input: MessagesIPCFindChatsRequest, access) in
            try requireAccess(access)
            return try MessagesChatDiscovery.find(input, database: database, aliases: aliases, contactName: contactName)
        }
    }

    static func searchMessages(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        aliases: @escaping @Sendable (String) throws -> [String] = { try contactAliases($0) },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) }
    ) throws -> Any {
        try perform(request: request, route: .searchMessages, permission: permission) { (input: MessagesIPCSearchMessagesRequest, access) in
            try requireAccess(access)
            do {
                return try MessagesReadPage.search(input, database: database, aliases: aliases, contactName: contactName)
            } catch let error as MessagesPaging.CursorError {
                throw ServiceError(.messagesInvalidRequest, error.message(tool: "search_messages"))
            }
        }
    }

    static func searchChats(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        aliases: @escaping @Sendable (String) throws -> [String] = { try contactAliases($0) },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) }
    ) throws -> Any {
        try perform(request: request, route: .searchChats, permission: permission) { (input: MessagesIPCSearchChatsRequest, access) in
            try requireAccess(access)
            return try MessagesChatDiscovery.search(input, database: database, aliases: aliases, contactName: contactName)
        }
    }

    static func countActivity(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) }
    ) throws -> Any {
        try perform(request: request, route: .countActivity, permission: permission) { (input: MessagesIPCCountActivityRequest, access) in
            try requireAccess(access)
            do {
                return try MessagesActivity.count(input, database: database, contactName: contactName)
            } catch let error as MessagesPaging.CursorError {
                throw ServiceError(.messagesInvalidRequest, error.message(tool: "count_message_activity"))
            }
        }
    }

    static func prepareSend(
        request: Any,
        permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision = { MessagesPermissionGate.shared.check() },
        database: @escaping @Sendable () throws -> URL = { defaultDatabase() },
        matches: @escaping @Sendable (String) throws -> [MessagesSendTargets.RecipientMatch] = { try MessagesSendTargets.contactMatches($0) },
        contactName: @escaping @Sendable (String) throws -> String? = { try contactDisplayName($0) },
        plans: MessagesSendPlans = sendPlans
    ) throws -> Any {
        try perform(request: request, route: .prepareSend, permission: permission) { (input: MessagesIPCPrepareSendRequest, access) in
            try requireAccess(access)
            return try plans.prepare(input) {
                try MessagesSendTargets.resolve($0, database: database, matches: matches, contactName: contactName)
            }
        }
    }

    static func commitSend(
        request: Any, files: [FileHandle], plans: MessagesSendPlans = sendPlans,
        permission: @escaping @MainActor @Sendable (MessagesSendPlans.Target) -> MessagesPermissionDecision = { target in
            let common = MessagesPermissionGate.shared.check()
            if case .granted = common, target.kind != .existingChat, !AXIsProcessTrusted() {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                return AXIsProcessTrustedWithOptions([key: true] as CFDictionary) ? .granted : .pending
            }
            return common
        },
        deliver: @escaping @Sendable (MessagesSendPlans.Attempt, MessagesSendFiles, @escaping @Sendable () throws -> Void) async throws -> Void = {
            try await MessagesDelivery.deliver($0, files: $1, checkpoint: $2)
        }
    ) throws -> Any {
        try perform(request: request, route: .commitSend) { (input: MessagesIPCCommitSendRequest, checkpoint) in
            let target = try plans.targetForClaim(input, fileCount: files.count)
            try requireAccess(await permission(target))
            try checkpoint()
            let (attempt, staged) = try plans.claim(input, fileCount: files.count, authorize: { _ in try checkpoint() }) {
                try MessagesSendFiles($0, files: files, checkpoint: checkpoint)
            }
            do {
                try await deliver(attempt, staged, checkpoint)
            } catch {
                throw ServiceError(.messagesSendOutcomeUncertain, "Messages delivery outcome is uncertain. The message may already have been sent.")
            }
            return attempt.result
        }
    }

    private static func perform<Input: Decodable & Sendable, Output: Encodable>(
        request: Any, route: MessagesIPCRoute, permission: @escaping @MainActor @Sendable () -> MessagesPermissionDecision,
        execute: @escaping @Sendable (Input, MessagesPermissionDecision) throws -> Output
    ) throws -> Any {
        try perform(request: request, route: route) { (input: Input, checkpoint) in
            let access = await permission()
            try checkpoint()
            return try execute(input, access)
        }
    }

    private static func perform<Input: Decodable & Sendable, Output: Encodable>(
        request: Any, route: MessagesIPCRoute,
        execute: @escaping @Sendable (Input, @escaping @Sendable () throws -> Void) async throws -> Output
    ) throws -> Any {
        let input: Input
        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
            input = try JSONDecoder().decode(Input.self, from: data)
        } catch {
            throw ServiceError(.couldNotGetRequestData, "Could not decode \(route.rawValue)")
        }
        guard !Thread.isMainThread else {
            throw ServiceError(.unknownError, "Messages requests require a connection worker")
        }
        let scope = RequestRuntime.workerScope()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let pending = PendingResult<Data>(discard: { _ in })
        let task = Task {
            do {
                let data = try await queue.sync {
                    let checkpoint: @Sendable () throws -> Void = {
                        try RequestRuntime.withWorkerScope(scope, cancelled: { cancelled.withLock { $0 } }) {
                            try RequestRuntime.check()
                        }
                    }
                    try checkpoint()
                    let output = try await execute(input, checkpoint)
                    try checkpoint()
                    return try JSONEncoder().encode(output)
                }
                pending.complete(.success(data))
            } catch let error as MessagesAttachmentStore.DatabaseError where error.isTimeout {
                pending.complete(.failure(ServiceError(.messagesQueryTimedOut, "Messages query timed out")))
            } catch let error as MessagesReadValidationError {
                pending.complete(.failure(ServiceError(.messagesInvalidRequest, error.description)))
            } catch {
                pending.complete(.failure(error))
            }
        }
        do {
            try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
            return try JSONSerialization.jsonObject(with: pending.take())
        } catch {
            cancelled.withLock { $0 = true }
            task.cancel()
            pending.abandon()
            throw error
        }
    }

    private static func requireAccess(_ permission: MessagesPermissionDecision) throws {
        switch permission {
        case .granted: break
        case .pending: throw ServiceError(.messagesPermissionsPending, "Messages permission setup is still open")
        case .denied: throw ServiceError(.messagesPermissionsDenied, "Required Messages permissions were not granted")
        }
    }

    static func executeImage(_ request: MessagesIPCReadImageRequest, permission: MessagesPermissionDecision,
                             database: () throws -> URL, contactName: (String) throws -> String?) throws -> MessagesIPCImage {
        try requireAccess(permission)
        do {
            return try MessagesImageRead.read(request) { id in
                let store = try MessagesAttachmentStore(file: database())
                guard let attachment = try store.locate(id) else { return nil }
                let name = try store.chatDisplayName(attachment.chatDisplayName, rowID: id.chatRowID, contactName: contactName)
                return .init(path: attachment.path, chatGUID: attachment.chatGUID, chatDisplayName: name)
            }
        } catch let error as MessagesReadValidationError {
            throw ServiceError(.messagesInvalidRequest, error.description)
        } catch is MessagesImageProcessor.Failure {
            throw ServiceError(.messagesInvalidRequest, "image attachment could not be processed")
        }
    }

    private static func defaultDatabase() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    private static func contactDisplayName(_ address: String) throws -> String? {
        let alias = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return nil }
        let predicate = alias.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: alias)
            : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: alias))
        let store = CNContactStore()
        let key = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        guard let contact = try store.unifiedContacts(matching: predicate, keysToFetch: [key]).first,
              let name = CNContactFormatter.string(from: contact, style: .fullName),
              name != alias, !name.isEmpty else { return nil }
        return name
    }

    private static func contactAliases(_ input: String) throws -> [String] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let range = NSRange(query.startIndex..., in: query)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        let detected = detector.matches(in: query, range: range).compactMap { match -> (NSRange, String)? in
            if let phone = match.phoneNumber { return (match.range, phone) }
            if let url = match.url, url.scheme == "mailto", let portion = Range(match.range, in: query) {
                return (match.range, String(query[portion]))
            }
            return nil
        }
        let predicate: NSPredicate
        if let (match, alias) = detected.first, match == range {
            predicate = alias.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: alias)
                : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: alias))
        } else {
            predicate = CNContact.predicateForContacts(matchingName: query)
        }
        let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let matches = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
        let aliases = matches.flatMap { contact in
            contact.emailAddresses.map { $0.value as String } + contact.phoneNumbers.map { $0.value.stringValue }
        }
        return aliases.isEmpty ? detected.map(\.1) : aliases
    }
}
