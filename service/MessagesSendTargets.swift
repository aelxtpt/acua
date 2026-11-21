import Contacts
import Foundation

enum MessagesSendTargets {
    struct RecipientMatch {
        let aliases: [String]
        let name: String?
    }

    static func resolve(_ destination: MessagesSendPlans.Destination, database: () throws -> URL,
                        matches: (String) throws -> [RecipientMatch], contactName: (String) throws -> String?) throws -> MessagesSendPlans.Target {
        switch destination {
        case .chat(let guid):
            let store = try MessagesAttachmentStore(file: database())
            guard let chat = try store.sendChat(guid) else {
                throw MessagesReadValidationError.invalid("chatGUID was not found")
            }
            return try existing(chat, store: store, contactName: contactName)
        case .recipients(let inputs):
            let groups = try inputs.map { input -> RecipientMatch in
                let candidates = try matches(input)
                let label = inputs.count == 1 ? "recipient" : "recipient \(input)"
                guard candidates.count <= 1 else {
                    throw ServiceError(.messagesAmbiguousDestination, "\(label) matches multiple contacts; retry with an exact phone number or email address")
                }
                guard let match = candidates.first else {
                    throw MessagesReadValidationError.invalid("\(label) was not found; use an exact phone number or email address")
                }
                guard !match.aliases.isEmpty else {
                    throw MessagesReadValidationError.invalid("\(label) has no reachable phone number or email address")
                }
                return match
            }
            let store = try MessagesAttachmentStore(file: database())
            if let chat = try store.sendChat(matching: groups.map(\.aliases), normalize: normalized) {
                return try existing(chat, store: store, contactName: contactName)
            }
            var chosen = Set<String>()
            let participants = try zip(inputs, groups).map { input, match -> MessagesIPCParticipant in
                let handle = normalized(match.aliases[0])
                guard chosen.insert(handle).inserted else {
                    throw MessagesReadValidationError.invalid("recipients must resolve to different phone numbers or email addresses")
                }
                let service = try store.latestService(for: handle)
                return .init(handle: handle, name: match.name ?? input, service: service)
            }
            return .init(kind: inputs.count == 1 ? .newDirectMessage : .newGroupMessage, chatGUID: nil,
                displayName: participants.map { $0.name ?? $0.handle }.joined(separator: ", "),
                participants: participants, service: inputs.count == 1 ? participants.first?.service : nil)
        }
    }

    private static func existing(_ chat: MessagesAttachmentStore.SendChat, store: MessagesAttachmentStore,
                                 contactName: (String) throws -> String?) throws -> MessagesSendPlans.Target {
        let participants = try store.chatParticipants(chat.rowID).map { source in
            var value = source
            value.name = try contactName(value.handle)
            return value
        }
        let name = chat.displayName.isEmpty ? participants.map { $0.name ?? $0.handle }.joined(separator: ", ") : chat.displayName
        return .init(kind: .existingChat, chatGUID: chat.guid, displayName: name, participants: participants, service: chat.service)
    }

    static func normalized(_ value: String) -> String {
        if value.contains("@") { return value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let phone = CNPhoneNumber(stringValue: value)
        let key = "unformattedInternationalStringValue"
        guard phone.responds(to: NSSelectorFromString(key)) else { return value }
        return phone.value(forKey: key) as? String ?? value
    }

    static func contactMatches(_ value: String) throws -> [RecipientMatch] {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        let range = NSRange(value.startIndex..., in: value)
        let detected = detector.matches(in: value, range: range).compactMap { match -> (NSRange, String)? in
            if let phone = match.phoneNumber { return (match.range, phone) }
            if match.url?.scheme == "mailto", let portion = Range(match.range, in: value) {
                return (match.range, String(value[portion]))
            }
            return nil
        }
        let predicate: NSPredicate
        if let (span, alias) = detected.first, span == range {
            predicate = alias.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: alias)
                : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: alias))
        } else {
            predicate = CNContact.predicateForContacts(matchingName: value)
        }
        let keys = [CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let contacts = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
        if contacts.isEmpty { return detected.map { .init(aliases: [$0.1], name: nil) } }
        return contacts.map { contact in
            let aliases = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
            var seen = Set<String>()
            return .init(aliases: aliases.filter { !$0.isEmpty && seen.insert(normalized($0)).inserted },
                name: CNContactFormatter.string(from: contact, style: .fullName))
        }
    }
}
