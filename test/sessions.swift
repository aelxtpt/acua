import Foundation

@main enum SessionTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1; print("PASS \(name)") }
        func rejects(_ name: String, code: CUErrorCode, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name + " accepted") }
            catch let e as ServiceError { check(name, e.code == code) }
            catch { preconditionFailure("unexpected error: \(error)") }
        }
        final class Clock { var time = 10.0 }
        let clock = Clock(), sessions = AppSessions(now: { clock.time })
        let app = IPCApp(pid: 123, bundleIdentifier: "com.example.fixture", appPath: "/tmp/Fixture.app")
        let json = jsonObject(try JSONEncoder().encode(IPCAppState(active: true, currentApp: app)))!
        check("AppState keys and nested App keys match Codable output", Set(json.keys) == ["active", "currentApp"] && Set(asDict(json["currentApp"])!.keys) == ["pid", "bundleIdentifier", "appPath"])
        check("inactive state omits a missing currentApp", IPCAppState(active: false, currentApp: nil).json.keys.sorted() == ["active"])
        check("missing appPath is omitted", IPCApp(pid: 1, bundleIdentifier: "x", appPath: nil).json["appPath"] == nil)
        rejects("actions cannot create a session implicitly", code: .noActiveSession) { _ = try sessions.prepare(app: app, process: "123:a", create: false) }
        let token = try sessions.prepare(app: app, process: "123:a", create: true)
        check("start returns active with the current process", try sessions.activate(token).currentApp == app)
        check("status snapshot includes the active process identity",
            sessions.activeApplications().map(\.process) == ["123:a"])
        check("background work joins only the active process generation",
              sessions.activeToken(for: app.bundleIdentifier, process: "123:a")?.epoch == token.epoch &&
              sessions.activeToken(for: app.bundleIdentifier, process: "123:b") == nil)
        try sessions.check(token)
        let stopped = sessions.stop(app.bundleIdentifier)
        check("stop retains currentApp metadata and returns inactive", !stopped.active && stopped.currentApp == app)
        check("status snapshot omits a stopped session", sessions.activeApplications().isEmpty)
        check("a stopped session admits no background work",
              sessions.activeToken(for: app.bundleIdentifier, process: "123:a") == nil)
        rejects("a held action observes user stop", code: .userStoppedSession) { try sessions.check(token) }
        rejects("a state query cannot silently clear user stop", code: .userStoppedSession) { _ = try sessions.prepare(app: app, process: "123:a", create: true, requery: true) }
        rejects("start cannot override user stop", code: .userStoppedSession) { try sessions.validateStart(app.bundleIdentifier) }
        rejects("process restart cannot bypass user stop", code: .userStoppedSession) { _ = try sessions.prepare(app: app, process: "new-process", create: true) }
        check("a rejected restart cannot discard the stopped session metadata", sessions.stop(app.bundleIdentifier).currentApp == app)
        sessions.clearStoppedByUser(app.bundleIdentifier)
        let resumed = try sessions.prepare(app: app, process: "123:b", create: true)
        rejects("old generation cannot act on a resumed session", code: .noActiveSession) { try sessions.check(token) }
        check("explicit host resume permits a new session", try sessions.activate(resumed).active)
        sessions.interrupt(app.bundleIdentifier)
        rejects("user intervention cancels the active token", code: .userIntervened) { try sessions.check(resumed) }
        check("an interrupted session admits no background work",
              sessions.activeToken(for: app.bundleIdentifier, process: "123:b") == nil)
        rejects("start is blocked before any physical activation during intervention", code: .userIntervened) { try sessions.validateStart(app.bundleIdentifier) }
        let early = try sessions.prepare(app: app, process: "123:b", create: true, requery: true)
        try sessions.check(early, requery: true); try sessions.didRequery(early)
        rejects("an early read does not bypass debounce", code: .userIntervened) { _ = try sessions.prepare(app: app, process: "123:b", create: false) }
        clock.time += 5
        rejects("time alone does not replace state requery", code: .userIntervened) { _ = try sessions.prepare(app: app, process: "123:b", create: false) }
        let read = try sessions.prepare(app: app, process: "123:b", create: true, requery: true)
        try sessions.didRequery(read)
        check("quiet state requery clears the intervention", try sessions.activate(read).active)
        sessions.interrupt(app.bundleIdentifier, debounce: 1)
        let reading = try sessions.prepare(app: app, process: "123:b", create: true, requery: true)
        sessions.interrupt(app.bundleIdentifier, debounce: 1)
        clock.time += 2
        rejects("intervention during capture invalidates its read token", code: .userIntervened) { try sessions.didRequery(reading) }
        let changed = try sessions.prepare(app: app, process: "123:b", create: true, requery: true)
        try sessions.didRequery(changed)
        let deactivated = try sessions.deactivate(changed)
        check("deactivation returns inactive without requiring app termination", !deactivated.active && deactivated.currentApp == app)
        check("status snapshot omits a deactivated session", sessions.activeApplications().isEmpty)
        rejects("deactivation invalidates the former token", code: .noActiveSession) { try sessions.check(changed) }
        rejects("deactivated session must be created again", code: .noActiveSession) { _ = try sessions.prepare(app: app, process: "123:b", create: false) }
        let reopened = try sessions.prepare(app: app, process: "123:b", create: true)
        sessions.interrupt(app.bundleIdentifier, debounce: 99)
        let restarted = try sessions.prepare(app: IPCApp(pid: 124, bundleIdentifier: app.bundleIdentifier, appPath: app.appPath), process: "124:c", create: true)
        rejects("process restart invalidates former tokens", code: .noActiveSession) { try sessions.check(reopened) }
        check("process restart clears interruption belonging to the old process", try sessions.activate(restarted).active)
        let other = IPCApp(pid: 222, bundleIdentifier: "com.example.other", appPath: nil)
        let independent = try sessions.prepare(app: other, process: "222:x", create: true)
        check("status snapshot preserves instance order and reflects replacement",
            sessions.activeApplications().map(\.process) == ["124:c", "222:x"])
        _ = sessions.stop(app.bundleIdentifier)
        try sessions.check(independent)
        check("stopping one app does not cancel another", true)
        let absent = sessions.stop("com.example.absent")
        check("stopping a missing session has no currentApp", !absent.active && absent.currentApp == nil)
        rejects("missing stopped session remains stopped", code: .userStoppedSession) { try sessions.validateStart("com.example.absent") }
        let guarded = AppSessions()
        let guardedToken = try guarded.prepare(app: app, process: "guarded", create: true)
        let otherToken = try guarded.prepare(app: other, process: "other-guarded", create: true)
        check("a new session has no pending settle", try !guarded.exchangeSettling(false, for: guardedToken))
        check("an action can defer settling until a later request", try !guarded.exchangeSettling(true, for: guardedToken))
        check("pending settling is scoped to the target app", try !guarded.exchangeSettling(false, for: otherToken))
        check("more input coalesces into one pending settle", try guarded.exchangeSettling(true, for: guardedToken))
        check("a native state requery consumes the pending settle", try guarded.exchangeSettling(false, for: guardedToken, requery: true))
        check("the next native state requery sees no pending settle", try !guarded.exchangeSettling(false, for: guardedToken, requery: true))
        try guarded.exchangeSettling(true, for: guardedToken)
        let newGuardedToken = try guarded.prepare(app: app, process: "new-guarded", create: true)
        check("process replacement clears pending settling", try !guarded.exchangeSettling(false, for: newGuardedToken))
        rejects("a replaced process cannot mark the new session as pending", code: .noActiveSession) {
            try guarded.exchangeSettling(true, for: guardedToken)
        }
        try guarded.exchangeSettling(true, for: newGuardedToken)
        guarded.interrupt(app.bundleIdentifier)
        rejects("an interrupted requery cannot consume settling with an old token", code: .userIntervened) {
            try guarded.exchangeSettling(false, for: newGuardedToken, requery: true)
        }
        let guardedRead = try guarded.prepare(app: app, process: "new-guarded", create: true, requery: true)
        check("a requery after intervention sees the new session generation's settling state",
              try !guarded.exchangeSettling(false, for: guardedRead, requery: true))
        let stopping = AppSessions()
        let stoppingToken = try stopping.prepare(app: app, process: "stopping", create: true)
        rejects("runtime propagates typed stop from a checkpoint", code: .userStoppedSession) {
            try RequestRuntime.withRequest([:]) {
                try RequestRuntime.withCheckpoint({ try stopping.check(stoppingToken) }) {
                    _ = stopping.stop(app.bundleIdentifier)
                    try RequestRuntime.wait(0.2)
                }
            }
        }
        try RequestRuntime.withRequest([:]) { try RequestRuntime.check() }
        check("checkpoint cleanup restores request context after failure", true)
        try RequestRuntime.withRequest(["senderPID": 999], peerPID: 123) {
            check("peer identity comes from trusted context instead of request fields", RequestRuntime.peerPID == 123)
            try RequestRuntime.withCheckpoint({}) { check("checkpoint preserves the trusted peer PID", RequestRuntime.peerPID == 123) }
        }
        check("peer identity cannot leak into the next request", RequestRuntime.peerPID == nil)
        var duration = Duration.seconds(5)
        let rawLow = withUnsafeBytes(of: &duration) { $0.loadUnaligned(as: UInt64.self) }
        check("debounce constant is a five-second Duration", rawLow == 5_000_000_000_000_000_000)
        let remote = AppSessions(), workers = DispatchGroup(), entered = DispatchSemaphore(value: 0)
        let remoteToken = try remote.prepare(app: app, process: "remote", create: true)
        final class Outcomes: @unchecked Sendable {
            let lock = NSLock(); var codes: [CUErrorCode] = []; var released = false
            func error(_ code: CUErrorCode) { lock.lock(); codes.append(code); lock.unlock() }
            func release() { lock.lock(); released = true; lock.unlock() }
        }
        let outcomes = Outcomes()
        workers.enter()
        DispatchQueue.global().async {
            defer { workers.leave() }
            do {
                try RequestRuntime.withRequest([:]) {
                    try RequestRuntime.serialized(app: "session-stop-fixture") {
                        try RequestRuntime.withCheckpoint({ try remote.check(remoteToken) }) {
                            defer { outcomes.release() }
                            entered.signal(); try RequestRuntime.wait(5)
                        }
                    }
                }
            } catch let e as ServiceError { outcomes.error(e.code) }
            catch { preconditionFailure("unexpected remote stop error") }
        }
        entered.wait()
        workers.enter()
        DispatchQueue.global().async {
            defer { workers.leave() }
            do {
                try RequestRuntime.withRequest([:]) {
                    try RequestRuntime.serialized(app: "session-stop-fixture") {
                        _ = try remote.prepare(app: app, process: "remote", create: false)
                        preconditionFailure("queued work executed after stop")
                    }
                }
            } catch let e as ServiceError { outcomes.error(e.code) }
            catch { preconditionFailure("unexpected queued stop error") }
        }
        let queueLimit = Date().addingTimeInterval(1)
        while RequestRuntime.queuedRequestCount(app: "session-stop-fixture") != 1 && Date() < queueLimit { Thread.sleep(forTimeInterval: 0.002) }
        check("second connection queues behind the held action", RequestRuntime.queuedRequestCount(app: "session-stop-fixture") == 1)
        _ = remote.stop(app.bundleIdentifier)
        check("stop from another thread cancels active and queued work promptly", workers.wait(timeout: .now() + 1) == .success)
        check("active and queued requests preserve the user-stopped error", outcomes.codes.count == 2 && outcomes.codes.allSatisfy { $0 == .userStoppedSession })
        check("stop unwinds held-action cleanup", outcomes.released)
        check("stopped work leaves no occupied app gate", RequestRuntime.activeAppCount == 0)
        print("\(count) session/runtime checks passed")
    }
}
