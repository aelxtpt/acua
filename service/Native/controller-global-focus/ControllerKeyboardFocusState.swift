import Foundation

/// Keyboard focus state is independent of AXFrontmost.
struct ControllerKeyboardFocusState: Sendable {
    enum Focus: Sendable, Equatable {
        case regular(Int32)
        case viewService(app: Int32, service: Int32?)
        var app: Int32 {
            switch self { case .regular(let pid), .viewService(let pid, _): return pid }
        }
        var unresolvedService: Bool {
            if case .viewService(_, nil) = self { return true }; return false
        }
    }
    struct Suppression: Sendable, Equatable {
        let thief: Int32
        let thiefApp: Int32
        let victim: Int32
        var released = false
        var returned = false
    }
    enum Notification: Sendable, Equatable { case lost(Int32), gained(Int32) }
    struct Change: Sendable {
        let notifications: [Notification]
        let release: Bool
        let inspectPreviousHost: Bool
        let updatesBridgeSuppression: Bool
    }
    private(set) var current: Focus
    private(set) var previous: Focus?
    private(set) var suppression: Suppression?
    private(set) var lastBridgeSuppression = false
    init(_ focus: Focus) { current = focus }

    mutating func taken(raw: Int32, focus: Focus, victim: Int32, protected: [Int32]) -> Bool {
        guard protected.contains(focus.app), focus.app != current.app else { suppression = nil; return false }
        suppression = .init(thief:raw, thiefApp:focus.app, victim:victim)
        return true
    }
    mutating func returned(to pid: Int32) -> Bool {
        guard var record = suppression, !record.returned, record.victim == pid else { return false }
        record.returned = true; suppression = record; return true
    }
    mutating func changed(raw: Int32, focus: Focus, protected: [Int32]) -> Change {
        let old = current
        previous = old; current = focus
        var notifications: [Notification] = []
        if old.app != focus.app {
            for pid in protected {
                let hidden = suppression.map { !$0.released && $0.thiefApp == pid } ?? false
                if !hidden {
                    if pid == focus.app { notifications.append(.gained(pid)) }
                    if pid == old.app { notifications.append(.lost(pid)) }
                }
            }
        }
        var release = false, matched = false
        if var record = suppression {
            if record.thief == raw {
                matched = true
                if !record.released { release = true; record.released = true; suppression = record }
            } else if record.victim != raw { suppression = nil }
        }
        let inspect = !matched && old.unresolvedService && focus.unresolvedService && old.app != focus.app && protected.contains(focus.app)
        return .init(notifications:notifications,release:release,inspectPreviousHost:inspect,updatesBridgeSuppression:focus.unresolvedService)
    }
    mutating func completed(_ change: Change, released: Bool) {
        if change.updatesBridgeSuppression { lastBridgeSuppression = released }
    }
    mutating func newFront(raw: Int32) -> Bool {
        if suppression?.thief == raw { suppression = nil }
        return lastBridgeSuppression
    }
    func keyboardRecipient(target: Int32) -> Int32? {
        guard let record = suppression, record.thief == target else { return nil }
        return record.victim
    }
}
