import Foundation

final class MessagesSendPlans: @unchecked Sendable {
    struct Target: Equatable, Sendable {
        let kind: MessagesIPCSendDestinationKind
        let chatGUID: String?
        let displayName: String
        let participants: [MessagesIPCParticipant]
        let service: MessagesIPCService?
    }

    enum Destination: Equatable {
        case chat(String)
        case recipients([String])
    }

    struct Attempt: Sendable {
        let target: Target
        let text: String?
        let attachments: [MessagesIPCSendAttachment]
        let startedAt: Date

        var result: MessagesIPCSendResult {
            .init(destinationKind: target.kind, chatGUID: target.chatGUID, displayName: target.displayName,
                participants: target.participants, service: target.service, text: text, attachments: attachments, sentAt: startedAt)
        }
    }

    func targetForClaim(_ input: MessagesIPCCommitSendRequest, fileCount: Int) throws -> Target {
        try lock.withLock { try planForClaim(input, fileCount: fileCount).target }
    }

    private struct Plan {
        let target: Target
        let attachments: [MessagesIPCSendAttachment]
        let expiresAt: Date
    }

    private struct Tombstone {
        let reason: MessagesIPCSendPlanUnavailableReason
        let retainUntil: Date
    }

    private static let planLifetime: TimeInterval = 300
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var plans = [UUID: Plan]()
    private var tombstones = [UUID: Tombstone]()
    private var recentSendDates = [Date]()

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func prepare(_ input: MessagesIPCPrepareSendRequest, resolve: (Destination) throws -> Target) throws -> MessagesIPCPreparedSend {
        let destination = try Self.validate(input)
        let target = try resolve(destination)
        let id = UUID()
        lock.withLock {
            let time = now()
            prune(at: time)
            plans[id] = Plan(target: target, attachments: input.attachments,
                expiresAt: time.addingTimeInterval(Self.planLifetime))
        }
        return .init(planID: id, chatGUID: target.chatGUID, displayName: target.displayName,
            text: input.text, attachments: input.attachments)
    }

    static func validate(_ input: MessagesIPCPrepareSendRequest) throws -> Destination {
        let hasChat = input.chatGUID != nil
        let hasRecipients = !input.recipients.isEmpty
        guard hasChat != hasRecipients else {
            throw MessagesReadValidationError.invalid("provide exactly one of chatGUID or recipients")
        }
        for attachment in input.attachments {
            let name = attachment.filename
            let component = name.prefix { $0 != "/" }
            guard !component.isEmpty, component != ".", component != "..", !name.contains("\0"),
                  name.dropFirst(component.count).allSatisfy({ $0 == "/" }) else {
                throw MessagesReadValidationError.invalid("attachment filenames must be non-empty names without path components")
            }
        }
        try requireContent(input.text, attachments: input.attachments)
        if let chatGUID = input.chatGUID {
            let guid = chatGUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !guid.isEmpty else { throw MessagesReadValidationError.invalid("chatGUID must not be empty") }
            return .chat(guid)
        }
        let recipients = input.recipients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !recipients.contains(where: \.isEmpty) else {
            throw MessagesReadValidationError.invalid("recipients must not contain empty values")
        }
        return .recipients(recipients)
    }

    // Stage all attachments before consuming the plan. A failed stage can be retried.
    func claim<Staged>(_ input: MessagesIPCCommitSendRequest, fileCount: Int,
                       authorize: (Target) throws -> Void,
                       stage: ([MessagesIPCSendAttachment]) throws -> Staged) throws -> (Attempt, Staged) {
        try lock.withLock {
            let plan = try planForClaim(input, fileCount: fileCount)
            try authorize(plan.target)
            let attemptDate = now()
            recentSendDates.removeAll { $0 <= attemptDate.addingTimeInterval(-60) }
            guard recentSendDates.count < 30 else {
                throw ControllerNativeServerError.messagesSendRateLimited(60)
            }
            let staged = try stage(plan.attachments)
            plans.removeValue(forKey: input.planID)
            tombstones[input.planID] = Tombstone(reason: .alreadyConsumed, retainUntil: now().addingTimeInterval(Self.planLifetime))
            recentSendDates.append(attemptDate)
            return (.init(target: plan.target, text: input.text, attachments: plan.attachments, startedAt: attemptDate), staged)
        }
    }

    private func planForClaim(_ input: MessagesIPCCommitSendRequest, fileCount: Int) throws -> Plan {
        prune(at: now())
        guard let plan = plans[input.planID] else {
            let reason = tombstones[input.planID]?.reason ?? .missing
            throw ControllerNativeServerError.messagesSendPlanUnavailable(.init(rawValue:reason.rawValue)!)
        }
        try Self.requireContent(input.text, attachments: plan.attachments)
        guard fileCount == plan.attachments.count else {
            throw MessagesReadValidationError.invalid("attachment file descriptors did not match the prepared send")
        }
        return plan
    }

    private func prune(at time: Date) {
        tombstones = tombstones.filter { $0.value.retainUntil > time }
        for (id, plan) in plans where plan.expiresAt <= time {
            plans.removeValue(forKey: id)
            tombstones[id] = Tombstone(reason: .expired, retainUntil: time.addingTimeInterval(Self.planLifetime))
        }
    }

    private static func requireContent(_ text: String?, attachments: [MessagesIPCSendAttachment]) throws {
        guard !attachments.isEmpty || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MessagesReadValidationError.invalid("messageText or attachments must not be empty")
        }
    }
}
