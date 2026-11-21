import Darwin
import Foundation

@main struct ScreenLockStateChecks {
    static func main() {
        if CommandLine.arguments.contains("--native") {
            let snapshot = ScreenLockState.read()
            let data: [String: Any] = ["state": snapshot.state.rawValue,
                "source": snapshot.source.rawValue, "reason": snapshot.reason,
                "interactionAvailable": snapshot.interactionAvailable,
                "onConsole": snapshot.onConsole as Any? ?? NSNull(),
                "readOnly": true, "inputOrCaptureOrUnlock": false]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        typealias S = ScreenLockState
        var results = [[String: Any]]()
        func check(_ name: String, _ condition: Bool) { results.append(["name": name, "passed": condition]) }
        let uid: uid_t = 501
        let unlocked: [String: Any] = [S.userKey: uid, S.consoleKey: true, S.loginKey: true, S.lockedKey: false]
        var locked = unlocked; locked[S.lockedKey] = true
        func read(_ primary: [String: Any]? = nil, _ rows: [[String: Any]]? = nil) -> S.Snapshot {
            S.read(currentUID: uid, session: { primary }, consoleUsers: { rows })
        }
        let lockedFallback = read(nil, [locked])
        check("absent CGSession still detects actual console lock", lockedFallback.state == .locked && !lockedFallback.interactionAvailable && lockedFallback.source == .consoleUsers)
        let unlockedFallback = read(nil, [unlocked])
        check("completed current console can authorize interaction", unlockedFallback.state == .unlocked && unlockedFallback.interactionAvailable)
        check("no data is unavailable, never unlocked", read().state == .unavailable && !read().interactionAvailable)
        check("empty console rows deny interaction", !read(nil, []).interactionAvailable)
        check("empty primary falls back", read([:], [locked]).state == .locked)
        check("false lock with absent console falls back", read([S.lockedKey: false], [locked]).state == .locked)
        check("known console with absent lock falls back", read([S.consoleKey: true], [locked]).state == .locked)
        var calls = 0
        let primary = S.read(currentUID: uid, session: { unlocked }, consoleUsers: { calls += 1; return [locked] })
        check("complete current session preserves primary source without registry read", primary.interactionAvailable && primary.source == .currentSession && calls == 0)
        check("primary true lock wins", read([S.lockedKey: true], [unlocked]).state == .locked)
        var offConsole = unlocked; offConsole[S.consoleKey] = false
        check("primary nonconsole does not authorize fallback", !read(offConsole, [unlocked]).interactionAvailable && read(offConsole, [unlocked]).onConsole == false)
        check("fallback nonconsole does not authorize", !read(nil, [offConsole]).interactionAvailable && read(nil, [offConsole]).onConsole == false)
        var foreign = unlocked; foreign[S.userKey] = uid + 1
        check("foreign primary cannot authorize", !read(foreign, [unlocked]).interactionAvailable)
        check("foreign console cannot authorize", !read(nil, [foreign]).interactionAvailable)
        check("own background row plus foreign console cannot authorize", !read(nil, [offConsole, foreign]).interactionAvailable)
        check("ambiguous console rows cannot authorize", !read(nil, [unlocked, foreign]).interactionAvailable)
        check("duplicate own console rows cannot authorize", !read(nil, [unlocked, unlocked]).interactionAvailable)
        check("old background row does not displace unique current console", read(nil, [offConsole, unlocked]).interactionAvailable)
        var row = unlocked; row.removeValue(forKey: S.userKey)
        check("missing UID cannot authorize", !read(nil, [row]).interactionAvailable)
        for (name, value) in [("boolean", true as Any), ("string", "501" as Any), ("negative", -1 as Any),
                              ("fraction", 501.5 as Any), ("overflow", UInt64.max as Any), ("NaN", Double.nan as Any)] {
            row = unlocked; row[S.userKey] = value
            check("invalid UID \(name) cannot authorize", !read(nil, [row]).interactionAvailable)
        }
        row = unlocked; row[S.userKey] = NSNumber(value: UInt32(501))
        check("integer NSNumber UID accepted", read(nil, [row]).interactionAvailable)
        for (name, value) in [("false", false as Any), ("absent", NSNull() as Any), ("number", 1 as Any), ("string", "true" as Any)] {
            row = unlocked; row[S.loginKey] = value
            check("incomplete or malformed login \(name) cannot authorize", !read(nil, [row]).interactionAvailable)
        }
        for (name, value) in [("absent", NSNull() as Any), ("zero", 0 as Any), ("string", "false" as Any)] {
            row = unlocked; row[S.lockedKey] = value
            check("missing or malformed lock \(name) cannot authorize", !read(nil, [row]).interactionAvailable)
        }
        for (name, value) in [("absent", NSNull() as Any), ("number", 1 as Any), ("string", "true" as Any)] {
            row = unlocked; row[S.consoleKey] = value
            check("missing or malformed console \(name) cannot authorize", !read(nil, [row]).interactionAvailable)
        }
        row = unlocked; row[S.lockedKey] = NSNumber(value: false)
        check("CFBoolean NSNumber accepted", read(nil, [row]).interactionAvailable)
        row = unlocked; row[S.userKey] = true
        check("malformed primary UID does not fall through to unlock", !read(row, [unlocked]).interactionAvailable)
        row = unlocked; row[S.lockedKey] = 0
        check("malformed primary lock uses actual console state", read(row, [locked]).state == .locked)
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        let output: [String: Any] = ["passed": passed, "cases": results.count, "results": results,
                                   "nativeUIInputCaptureUnlockOrPowerExecuted": false]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
