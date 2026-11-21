import Foundation

enum MessagesActivity {
    private static let tool = "count_message_activity"
    private static let zero = MessagesIPCActivityCount(total: 0, sent: 0, received: 0)

    static func count(_ input: MessagesIPCCountActivityRequest, database: () throws -> URL,
                      contactName: (String) throws -> String?, now: Date = Date(),
                      timeZone: TimeZone = .current) throws -> MessagesIPCActivityResult {
        let guids = Set(input.chatGUIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).sorted()
        guard !guids.contains(where: \.isEmpty) else {
            throw MessagesReadValidationError.invalid("chatGUIDs must not contain empty values")
        }
        guard input.breakdown == .chat || input.cursor == nil else {
            throw MessagesReadValidationError.invalid("cursor is only supported for chat breakdowns")
        }
        let filters = MessagesActivityFilters(fromDate: input.fromDate, toDate: input.toDate, interval: input.interval,
            chatType: input.chatType, chatGUIDs: guids, breakdown: input.breakdown, rankBy: input.rankBy)
        let cursor = try input.cursor.map { try MessagesPaging.activity($0, filters: filters) }
        let store = try MessagesAttachmentStore(file: database(), timeoutSeconds: 30)
        let bound = try cursor?.messageRowIDUpperBound ?? store.messageRowIDUpperBound()
        let state: MessagesActivityCursorState
        if let saved = cursor?.state {
            state = saved
        } else {
            let to = input.toDate ?? now
            let from = try input.fromDate ?? store.earliestActivity(filters, to: to, upperBound: bound) ?? to
            state = .init(range: .init(from: from, to: to), timeZoneIdentifier: timeZone.identifier)
        }
        guard state.range.from <= state.range.to else {
            throw MessagesReadValidationError.invalid("fromDate must not be later than toDate")
        }
        guard let zone = TimeZone(identifier: state.timeZoneIdentifier) else { throw MessagesPaging.CursorError.malformed }
        let buckets = try makeBuckets(state.range, interval: input.interval, timeZone: zone)
        var result = MessagesIPCActivityResult(breakdown: input.breakdown, range: state.range, interval: input.interval,
            timeZoneIdentifier: state.timeZoneIdentifier, buckets: buckets, matchingChatCount: 0)

        switch input.breakdown {
        case .overall:
            let summary = try store.overallActivity(filters, range: state.range, upperBound: bound)
            result.matchingChatCount = summary.matchingChats
            let counts = input.interval == .total
                ? buckets.map { _ in summary.counts }
                : filled(buckets, try store.activityBuckets(filters, range: state.range, upperBound: bound, buckets: buckets)[0])
            result.overallActivity = .init(total: summary.counts.total, sent: summary.counts.sent,
                received: summary.counts.received, countsByBucket: counts)
        case .chat:
            let bucketLimit = buckets.isEmpty ? 100 : 1000 / buckets.count
            let limit = min(max(input.chatLimit, 0), 100, bucketLimit)
            let ranked = try store.rankedActivity(filters, range: state.range, upperBound: bound,
                before: cursor?.lastReturnedSortKey, limit: limit + 1)
            result.matchingChatCount = ranked.matchingChats
            let page = ranked.chats.prefix(limit)
            let counts = input.interval == .total ? [:] : try store.activityBuckets(filters, range: state.range,
                upperBound: bound, buckets: buckets, chatRows: page.map(\.key.chatRowID))
            var participants = MessagesParticipantReferences()
            result.chats = try page.map { chat in
                let handles = try store.chatParticipants(Int64(chat.key.chatRowID)).map { participant in
                    var item = participant
                    item.name = try contactName(item.handle)
                    return item
                }
                let name = chat.displayName.isEmpty ? handles.map { $0.name ?? $0.handle }.joined(separator: ", ") : chat.displayName
                let breakdown = input.interval == .total ? buckets.map { _ in chat.counts }
                    : filled(buckets, counts[chat.key.chatRowID])
                return .init(guid: chat.guid, displayName: name, service: chat.service, type: chat.type,
                    participants: handles.map { participants.add($0) }, total: chat.counts.total,
                    sent: chat.counts.sent, received: chat.counts.received, countsByBucket: breakdown)
            }
            result.participants = participants.values
            if ranked.chats.count > limit, let last = page.last {
                result.nextCursor = try MessagesPaging.ActivityCursor(lastReturnedSortKey: last.key,
                    messageRowIDUpperBound: bound, state: state,
                    fingerprint: MessagesPaging.fingerprint(MessagesActivityFingerprint(filters, state)),
                    formatVersion: 1, tool: tool).encoded()
            }
        }
        return result
    }

    private static func filled(_ buckets: [MessagesIPCActivityRange],
                               _ counts: [Int: MessagesIPCActivityCount]?) -> [MessagesIPCActivityCount] {
        buckets.indices.map { counts?[$0] ?? zero }
    }

    static func makeBuckets(_ range: MessagesIPCActivityRange, interval: MessagesIPCActivityInterval,
                            timeZone: TimeZone) throws -> [MessagesIPCActivityRange] {
        guard range.from < range.to else { return [] }
        let component: Calendar.Component
        let limit: Int
        switch interval {
        case .total: return [range]
        case .day: (component, limit) = (.day, 366)
        case .week: (component, limit) = (.weekOfYear, 260)
        case .month: (component, limit) = (.month, 240)
        case .year: (component, limit) = (.year, 100)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        var buckets = [MessagesIPCActivityRange]()
        var from = range.from
        while from < range.to {
            guard buckets.count < limit else {
                throw MessagesReadValidationError.invalid("the requested range exceeds the maximum number of \(interval.rawValue) buckets (\(limit))")
            }
            guard let end = calendar.dateInterval(of: component, for: from)?.end, end > from else {
                throw MessagesReadValidationError.invalid("the requested date range could not be grouped into \(interval.rawValue) buckets")
            }
            let to = min(range.to, end)
            buckets.append(.init(from: from, to: to))
            from = to
        }
        return buckets
    }
}
