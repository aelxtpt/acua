import CoreGraphics
import Darwin
import Foundation
import IOKit

/// CGSession can be absent even in a logged-in, locked desktop session.
/// Reads the current CGSession first and falls back to the console-user list.
enum ScreenLockState {
    enum State: String, Sendable { case locked, unlocked, unavailable }
    enum Source: String, Sendable { case currentSession, consoleUsers, unavailable }
    struct Snapshot: Sendable {
        let state: State
        let source: Source
        let onConsole: Bool?
        let reason: String
        var interactionAvailable: Bool { state == .unlocked && onConsole == true }
    }

    static let lockedKey = "CGSSessionScreenIsLocked"
    static let consoleKey = "kCGSSessionOnConsoleKey"
    static let userKey = "kCGSSessionUserIDKey"
    static let loginKey = "kCGSessionLoginDoneKey"

    static func read(currentUID: uid_t = getuid(),
                     session: () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] },
                     consoleUsers: () -> [[String: Any]]? = nativeConsoleUsers) -> Snapshot {
        if let primary = currentSession(session(), currentUID: currentUID) { return primary }
        return consoleState(consoleUsers(), currentUID: currentUID)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func userID(_ value: Any?) -> uid_t? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(uid_t.max),
              value.rounded(.towardZero) == value else { return nil }
        return uid_t(value)
    }

    private static func currentSession(_ session: [String: Any]?, currentUID: uid_t) -> Snapshot? {
        guard let session else { return nil }
        // Never let another user's unlocked session authorize this process.
        if let rawUID = session[userKey], userID(rawUID) != currentUID {
            return .init(state: .unavailable, source: .currentSession, onConsole: nil, reason: "differentUser")
        }
        let onConsole = boolean(session[consoleKey])
        if boolean(session[lockedKey]) == true {
            return .init(state: .locked, source: .currentSession, onConsole: onConsole, reason: "locked")
        }
        if onConsole == false {
            return .init(state: .unavailable, source: .currentSession, onConsole: false, reason: "notOnConsole")
        }
        if boolean(session[lockedKey]) == false && onConsole == true {
            return .init(state: .unlocked, source: .currentSession, onConsole: true, reason: "unlocked")
        }
        // macOS removes the lock key after unlocking. A logged-in own
        // console session supplies positive identity/state evidence; an absent
        // key is distinct from a present invalid value such as NSNull.
        if session[lockedKey] == nil, onConsole == true,
           boolean(session[loginKey]) == true, userID(session[userKey]) == currentUID {
            return .init(state: .unlocked, source: .currentSession, onConsole: true, reason: "unlocked")
        }
        return nil
    }

    static func consoleState(_ users: [[String: Any]]?, currentUID: uid_t) -> Snapshot {
        guard let users else {
            return .init(state: .unavailable, source: .unavailable, onConsole: nil, reason: "noConsoleData")
        }
        let ownRows = users.filter { userID($0[userKey]) == currentUID }
        guard !ownRows.isEmpty else {
            return .init(state: .unavailable, source: .consoleUsers, onConsole: nil, reason: "noCurrentUser")
        }
        let onConsole = users.filter { boolean($0[consoleKey]) == true }
        guard onConsole.count == 1, let row = onConsole.first,
              userID(row[userKey]) == currentUID else {
            return .init(state: .unavailable, source: .consoleUsers,
                         onConsole: ownRows.allSatisfy { boolean($0[consoleKey]) == false } ? false : nil,
                         reason: "noUniqueCurrentConsole")
        }
        guard boolean(row[loginKey]) == true else {
            return .init(state: .unavailable, source: .consoleUsers, onConsole: true, reason: "loginNotComplete")
        }
        // The unique own on-console user and completed login were checked
        // above. A missing lock key is the normal unlocked representation.
        if row[lockedKey] == nil {
            return .init(state: .unlocked, source: .consoleUsers, onConsole: true, reason: "unlocked")
        }
        guard let locked = boolean(row[lockedKey]) else {
            return .init(state: .unavailable, source: .consoleUsers, onConsole: true, reason: "missingLockState")
        }
        return .init(state: locked ? .locked : .unlocked, source: .consoleUsers,
                     onConsole: true, reason: locked ? "locked" : "unlocked")
    }

    static func nativeConsoleUsers() -> [[String: Any]]? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]]
    }
}
