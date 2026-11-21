import Foundation
import CoreGraphics

@main enum InterventionTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1; print("PASS \(name)") }
        func interrupted(_ sessions: AppSessions, _ token: AppSessions.Token) -> Bool {
            do { try sessions.check(token); return false }
            catch let error as ServiceError { return error.code == .userIntervened }
            catch { return false }
        }
        let own: Int32 = 900
        func input(_ type: CGEventType = .leftMouseDown, source: Int64 = 0, target: Int64 = 101, window: Int64? = 50) -> UserInteraction {
            UserInteraction(type: type, sourcePID: source, targetPID: target, windowID: window)
        }
        check("five-event mask covers the intervention event types", UserInteraction.mask == [1, 3, 25, 22, 10].reduce(UInt64(0)) { $0 | (1 << $1) })
        for type in UserInteraction.eventTypes {
            check("external \(type) is observed", input(type).isExternal(to: own))
            check("own \(type) does not cancel automation", !input(type, source: Int64(own)).isExternal(to: own))
        }
        for type: CGEventType in [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .keyUp, .flagsChanged, .tapDisabledByTimeout, .tapDisabledByUserInput] {
            check("\(type) does not count as intervention", !input(type).isExternal(to: own))
        }
        check("source overflow is rejected instead of trapping", !input(source: Int64.max).isExternal(to: own))
        check("target overflow is rejected instead of trapping", !input(target: Int64.max).isExternal(to: own))
        check("an external synthesized source is treated as external input", input(source: 901).isExternal(to: own))
        check("window owner takes priority over event target", input().target { $0 == 50 ? 202 : nil } == 202)
        check("unknown window falls back to event target", input().target { _ in nil } == 101)
        check("missing window falls back to event target", input(window: nil).target { _ in preconditionFailure("unexpected lookup") } == 101)
        check("negative window cannot wrap to another window", input(window: -1).target { _ in preconditionFailure("unexpected lookup") } == 101)
        check("overflowing window cannot wrap", input(window: Int64.max).target { _ in preconditionFailure("unexpected lookup") } == 101)
        check("unknown target does not fall back to unrelated frontmost app", input(target: 0).target { _ in nil } == nil)
        check("window can identify target when event target is absent", input(target: 0).target { _ in 202 } == 202)
        check("invalid owner does not cancel a global session", input(target: 0).target { _ in -1 } == nil)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        UserInteraction.markSynthesized(event, servicePID: own)
        let stamped = input(.keyDown, source: event.getIntegerValueField(.eventSourceUnixProcessID))
        check("native CGEvent source stamp excludes automation events", !stamped.isExternal(to: own))

        final class Clock { var now = 1.0 }
        let clock = Clock(), sessions = AppSessions(now: { clock.now })
        let app = IPCApp(pid: 101, bundleIdentifier: "fixture.one", appPath: nil)
        let other = IPCApp(pid: 202, bundleIdentifier: "fixture.two", appPath: nil)
        let first = try sessions.prepare(app: app, process: "101:one", create: true)
        let second = try sessions.prepare(app: other, process: "202:two", create: true)
        check("input in an unrelated process is ignored", sessions.interrupt(pid: 999).isEmpty)
        try sessions.check(first); try sessions.check(second)
        check("a reused PID with a different launch identity cannot cancel an old session", sessions.interrupt(pid: 101, process: "101:different-launch").isEmpty)
        try sessions.check(first)
        check("only matching active process is interrupted", sessions.interrupt(pid: 101, process: "101:one") == [app.bundleIdentifier])
        check("matching active token is cancelled", interrupted(sessions, first))
        try sessions.check(second)
        check("a second app remains usable", true)
        clock.now = 5
        _ = sessions.interrupt(pid: 101)
        clock.now = 6
        let early = try sessions.prepare(app: app, process: "101:one", create: false, requery: true)
        try sessions.didRequery(early)
        check("further human input extends debounce beyond original deadline", interrupted(sessions, early))
        clock.now = 10
        let quiet = try sessions.prepare(app: app, process: "101:one", create: false, requery: true)
        try sessions.didRequery(quiet); try sessions.check(quiet)
        check("state requery after final quiet interval resumes", true)
        _ = sessions.stop(app.bundleIdentifier)
        check("human input cannot turn a stopped session into interrupted", sessions.interrupt(pid: 101).isEmpty)
        do { try sessions.validateStart(app.bundleIdentifier); preconditionFailure("stop bypassed") }
        catch let e as ServiceError { check("user stop retains precedence", e.code == .userStoppedSession) }
        _ = try sessions.deactivate(second)
        check("deactivated process is ignored", sessions.interrupt(pid: 202).isEmpty)
        sessions.clearStoppedByUser(app.bundleIdentifier)
        let restartedApp = IPCApp(pid: 303, bundleIdentifier: app.bundleIdentifier, appPath: nil)
        let restarted = try sessions.prepare(app: restartedApp, process: "303:new", create: true)
        check("old process cannot interrupt a restarted app", sessions.interrupt(pid: 101).isEmpty)
        try sessions.check(restarted)
        check("new process can still be interrupted", sessions.interrupt(pid: 303) == [app.bundleIdentifier] && interrupted(sessions, restarted))
        print("\(count) intervention checks passed (policy/session logic and local CGEvent; no event tap delivery claim)")
    }
}
