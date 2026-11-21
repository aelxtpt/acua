import AppKit

@main
enum InputTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, name); passed += 1; print("PASS \(name)") }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name + " accepted invalid input") }
            catch is ServiceError { passed += 1; print("PASS \(name)") }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        check("numeric helpers reject boolean coercion", intValue(true) == nil && doubleValue(false) == nil)
        check("integer helper rejects fractions and overflow", intValue(1.5) == nil && intValue(UInt64.max) == nil)
        check("integer-valued numbers remain valid", intValue(1.0) == 1 && intValue(Int.max) == Int.max)
        check("floating helper rejects non-finite values", doubleValue(Double.infinity) == nil && doubleValue(Double.nan) == nil)
        check("boolean helper rejects numeric values", boolValue(1) == nil && boolValue(true) == true)
        let aliases = [["com.example.alpha", "Alpha", "/Applications/Alpha.app"],
                       ["com.example.alphabet", "Alphabet"], ["com.example.beta", "Beta"]]
        check("all 14 native target entries are present", NativeTargetPolicy.forbidden.count == 14)
        for target in NativeTargetPolicy.forbidden.sorted() {
            check("native policy forbids \(target)", NativeTargetPolicy.isForbidden(target, allowForbidden: false))
            check("allow-forbidden preference overrides \(target)", !NativeTargetPolicy.isForbidden(target, allowForbidden: true))
        }
        check("native policy allows unrelated apps", !NativeTargetPolicy.isForbidden("com.example.fixture", allowForbidden: false))
        check("native policy equality does not block a prefix lookalike", !NativeTargetPolicy.isForbidden("com.apple.Terminal.example", allowForbidden: false))
        check("exact app alias wins over partial matches", try AppResolver.match("Alpha", aliases: aliases) == 0)
        check("case-insensitive exact app alias wins", try AppResolver.match("ALPHA", aliases: aliases) == 0)
        check("unique partial app name resolves", try AppResolver.match("betA", aliases: aliases) == 2)
        check("exact path resolves", try AppResolver.match("/Applications/Alpha.app", aliases: aliases) == 0)
        check("unknown app stays unresolved", try AppResolver.match("unknown", aliases: aliases) == nil)
        rejects("partial app name is rejected when ambiguous") { _ = try AppResolver.match("alph", aliases: aliases) }
        rejects("duplicate exact app names are ambiguous") { _ = try AppResolver.match("Alpha", aliases: [["Alpha"], ["Alpha"]]) }
        for value in ["", " ", "\n\t"] {
            rejects("empty app cannot select a running process") { _ = try AppResolver.match(value, aliases: aliases) }
        }
        var decoder = FrameDecoder()
        let ping = encodeFrame("{}")
        var oversized = UInt32(kMaxFrameBytes + 1).littleEndian
        let invalidHeader = withUnsafeBytes(of: &oversized) { Data($0) }
        check("valid frames before a poisoned header are preserved", decoder.append(ping + invalidHeader) == [Data("{}".utf8)])
        check("oversized frame marks decoder terminal", decoder.failure?.code == .couldNotGetRequestData)
        check("terminal decoder rejects future bytes", decoder.append(ping).isEmpty)
        var unicodeDecoder = FrameDecoder()
        let invalidBody = unicodeDecoder.append(Data([1, 0, 0, 0, 255]))
        check("framing preserves bytes and JSON decoding rejects invalid encoding", invalidBody == [Data([255])] && jsonFrameObject(invalidBody[0]) == nil)
        var fragmented = FrameDecoder()
        let unicodeFrame = encodeFrame("🙂")
        check("fragmented UTF-8 frame waits for all bytes", fragmented.append(unicodeFrame.prefix(6)).isEmpty)
        check("fragmented UTF-8 frame round trips", fragmented.append(unicodeFrame.dropFirst(6)) == [Data("🙂".utf8)])
        check("selection uses UTF-16 after emoji", try TextSelection.range(in: "🙂 café fim", text: "café") == NSRange(location: 3, length: 4))
        check("canonical Unicode match preserves actual source length", try TextSelection.range(in: "🙂 cafe\u{301} fim", text: "café") == NSRange(location: 3, length: 5))
        check("prefix disambiguates but is not selected", try TextSelection.range(in: "x foo y | z foo y", text: "foo", prefix: "z ") == NSRange(location: 12, length: 3))
        check("suffix disambiguates repeated text", try TextSelection.range(in: "foo? foo!", text: "foo", suffix: "!") == NSRange(location: 5, length: 3))
        check("cursor-before excludes prefix", try TextSelection.range(in: "x foo y | z foo y", text: "foo", prefix: "z ", selection: "cursor_before") == NSRange(location: 12, length: 0))
        check("cursor-after uses UTF-16 end", try TextSelection.range(in: "🙂 café fim", text: "café", selection: "cursor_after") == NSRange(location: 7, length: 0))
        check("overlapping matches can be disambiguated", try TextSelection.range(in: "aaa", text: "aa", prefix: "a") == NSRange(location: 1, length: 2))
        check("joined emoji range remains intact", try TextSelection.range(in: "a👩🏽‍💻b", text: "👩🏽‍💻") == NSRange(location: 1, length: 7))
        rejects("ambiguous repeated text") { _ = try TextSelection.range(in: "foo foo", text: "foo") }
        rejects("ambiguous overlapping text") { _ = try TextSelection.range(in: "aaa", text: "aa") }
        rejects("missing text never selects position zero") { _ = try TextSelection.range(in: "abc", text: "xyz") }
        rejects("incorrect context is not ignored") { _ = try TextSelection.range(in: "abc", text: "b", prefix: "x") }
        check("a context containing a source combining unit can match the source UTF-16 boundary",
              try TextSelection.range(in: "e\u{301}text", text: "text", prefix: "\u{301}") == NSRange(location: 2, length: 4))
        check("fixed-length context selects only the composed occurrence",
              try TextSelection.range(in: "e\u{301}text étext", text: "text", prefix: "é") == NSRange(location: 8, length: 4))
        check("CRLF prefix matches its final source code unit",
              try TextSelection.range(in: "x\r\ntext", text: "text", prefix: "\n") == NSRange(location: 3, length: 4))
        rejects("composed prefix does not span extra source UTF-16 units") {
            _ = try TextSelection.range(in: "e\u{301}text", text: "text", prefix: "é")
        }
        rejects("decomposed suffix cannot exceed the remaining source UTF-16 units") {
            _ = try TextSelection.range(in: "texté", text: "text", suffix: "e\u{301}")
        }
        rejects("empty text") { _ = try TextSelection.range(in: "abc", text: "") }
        rejects("unknown selection mode") { _ = try TextSelection.range(in: "abc", text: "b", selection: "replace") }
        let chord = try KeyChord.parse("Cmd+Shift+Return")
        check("modified shortcut preserves modifiers and physical key", chord.key == 36 && chord.flags.contains([.maskCommand, .maskShift]))
        check("right-side modifier maps to right physical key", try KeyChord.parse("Shift_R").modifiers.first?.code == 60)
        check("duplicate modifiers are held only once", try KeyChord.parse("Shift+Shift_L+a").modifiers.count == 1)
        check("plus shortcut can be expressed without losing its key", try KeyChord.parse("Super_L++").key == 24)
        check("literal plus includes shift", try KeyChord.parse("+").flags.contains(.maskShift))
        check("plain Unicode key remains a literal", try KeyChord.parse("é").literal == "é")
        for input in ["", "Cmd+", "Cmd++a", "a+b", "Hyper+a", "Cmd+é"] {
            rejects("invalid chord '\(input)'") { _ = try KeyChord.parse(input) }
        }
        check("ordinary click may use AXPress", try ClickOptions([:]).canUseAXPress)
        for options: JSON in [["mouseButton": 1], ["mouseButton": 5], ["clickCount": 2], ["duration": 0.1], ["key": "Shift"]] {
            check("special click cannot degrade into AXPress", try !ClickOptions(options).canUseAXPress)
        }
        check("native extra mouse buttons retain their UInt32 value", try ClickOptions(["mouseButton": UInt32.max]).button == Int(UInt32.max))
        check("native click count is not capped at one hundred", try ClickOptions(["clickCount": 101]).count == 101)
        check("native click count accepts the signed wire maximum", try ClickOptions(["clickCount": Int.max]).count == Int.max)
        for options: JSON in [["clickCount": 0], ["clickCount": -1], ["clickCount": 1.2], ["clickCount": true], ["clickCount": UInt64(Int.max) + 1],
                              ["mouseButton": UInt64(UInt32.max) + 1], ["mouseButton": -1], ["mouseButton": "left"], ["duration": -1],
                              ["duration": Double.infinity], ["duration": Double.nan], ["duration": true], ["duration": 3601], ["key": 1]] {
            rejects("invalid click options \(options)") { _ = try ClickOptions(options) }
        }
        check("missing key duration defaults to zero", try KeyChord.duration(nil) == 0)
        rejects("expired request is rejected before body") {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": 0]) { preconditionFailure("expired body executed") }
        }
        rejects("boolean deadline is rejected") { try RequestRuntime.withRequest(["deadlineUnixMilliseconds": true]) {} }
        try RequestRuntime.withRequest(["deadlineUnixMilliseconds": NSNull()]) { try RequestRuntime.check() }
        check("explicit null deadline behaves like an absent optional deadline", true)
        let now = Date().timeIntervalSince1970 * 1000
        let start = ProcessInfo.processInfo.systemUptime
        rejects("hold checks its deadline while waiting") {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": now + 25]) { try RequestRuntime.wait(1) }
        }
        check("deadline interrupts a long wait promptly", ProcessInfo.processInfo.systemUptime - start < 0.2)
        rejects("deadline interrupts a callback that never fires") {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": Date().timeIntervalSince1970 * 1000 + 20]) {
                try RequestRuntime.wait(for: DispatchSemaphore(value: 0), maximumSeconds: 10)
            }
        }
        rejects("callback wait has a cap even without a request scope") {
            try RequestRuntime.wait(for: DispatchSemaphore(value: 0), maximumSeconds: 0.02)
        }
        let completedCallback = DispatchSemaphore(value: 0)
        completedCallback.signal()
        try RequestRuntime.wait(for: completedCallback, maximumSeconds: 1)
        check("completed callback wait returns", true)
        try RequestRuntime.withRequest([:]) {
            rejects("nested expired scope") { try RequestRuntime.withRequest(["deadlineUnixMilliseconds": 0]) {} }
            try RequestRuntime.check()
        }
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var active = 0, maximum = 0, finished = 0
        }
        let state = State(), group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                try! RequestRuntime.serialized(app: "fixture") {
                    state.lock.lock(); state.active += 1; state.maximum = max(state.maximum, state.active); state.lock.unlock()
                    Thread.sleep(forTimeInterval: 0.015)
                    state.lock.lock(); state.active -= 1; state.finished += 1; state.lock.unlock()
                }
            }
        }
        check("queued actions complete", group.wait(timeout: .now() + 2) == .success)
        check("separate connections cannot overlap an app action", state.maximum == 1 && state.finished == 4)
        let entered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try! RequestRuntime.serialized(app: "busy") { entered.signal(); Thread.sleep(forTimeInterval: 0.15) }
            done.signal()
        }
        entered.wait()
        rejects("request can expire while queued behind another client") {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": Date().timeIntervalSince1970 * 1000 + 20]) {
                try RequestRuntime.serialized(app: "busy") { preconditionFailure("expired queued action executed") }
            }
        }
        check("busy action cleans up its gate", done.wait(timeout: .now() + 1) == .success)
        rejects("cancelled request never begins") {
            try RequestRuntime.withRequest([:], cancelled: { true }) { preconditionFailure("cancelled body ran") }
        }
        rejects("nested scopes cannot suppress parent cancellation") {
            var cancelled = false
            try RequestRuntime.withRequest([:], cancelled: { cancelled }) {
                cancelled = true
                try RequestRuntime.withRequest([:]) { try RequestRuntime.check() }
            }
        }
        try RequestRuntime.withRequest([:]) {
            try RequestRuntime.serialized(app: "recursive") {
                try RequestRuntime.serialized(app: "recursive") { try RequestRuntime.check() }
            }
        }
        check("per-app queue supports nested calls on its owning thread", true)
        final class Order: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int] = []
            var cancelled = false
            func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
            func cancel() { lock.lock(); cancelled = true; lock.unlock() }
            func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        }
        let order = Order(), fifo = DispatchGroup()
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        fifo.enter()
        DispatchQueue.global().async {
            defer { fifo.leave() }
            try! RequestRuntime.serialized(app: "fifo") { holding.signal(); release.wait() }
        }
        holding.wait()
        for index in 0..<3 {
            fifo.enter()
            DispatchQueue.global().async {
                defer { fifo.leave() }
                try! RequestRuntime.serialized(app: "fifo") { order.append(index) }
            }
            let until = Date().addingTimeInterval(1)
            while RequestRuntime.queuedRequestCount(app: "fifo") != index + 1 && Date() < until { Thread.sleep(forTimeInterval: 0.002) }
            check("request \(index) reaches the FIFO queue", RequestRuntime.queuedRequestCount(app: "fifo") == index + 1)
        }
        let cancelledDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { cancelledDone.signal() }
            do {
                try RequestRuntime.withRequest([:], cancelled: { order.isCancelled() }) {
                    try RequestRuntime.serialized(app: "fifo") { preconditionFailure("cancelled queued work ran") }
                }
            } catch is ServiceError {} catch { preconditionFailure("unexpected error") }
        }
        let queuedUntil = Date().addingTimeInterval(1)
        while RequestRuntime.queuedRequestCount(app: "fifo") != 4 && Date() < queuedUntil { Thread.sleep(forTimeInterval: 0.002) }
        check("cancellable work entered queue", RequestRuntime.queuedRequestCount(app: "fifo") == 4)
        order.cancel()
        check("queued cancellation does not wait for owner to finish", cancelledDone.wait(timeout: .now() + 1) == .success)
        check("cancelled waiter is removed", RequestRuntime.queuedRequestCount(app: "fifo") == 3)
        release.signal()
        check("FIFO queue drains after cancellation", fifo.wait(timeout: .now() + 1) == .success)
        check("actions execute in arrival order", order.values == [0, 1, 2])
        check("idle queues are released rather than retained forever", RequestRuntime.activeAppCount == 0)
        final class MainTransfer: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            var passed = false
            func finish(_ result: Bool) { lock.withLock { passed = result; done = true } }
        }
        let transfer = MainTransfer()
        DispatchQueue.global().async {
            do {
                var cancelled = false
                try RequestRuntime.withRequest([:], cancelled: { cancelled }, peerPID: 12345) {
                    try RequestRuntime.onMainThread {
                        guard Thread.isMainThread, RequestRuntime.peerPID == 12345 else { return }
                        cancelled = true
                        do { try RequestRuntime.check() }
                        catch is ServiceError { transfer.finish(true); return }
                        catch { return }
                    }
                }
            } catch is ServiceError {
                // The main-thread post-check also observes the cancellation.
            } catch {}
            if !transfer.lock.withLock({ transfer.done }) { transfer.finish(false) }
        }
        let transferDeadline = Date().addingTimeInterval(3)
        while !transfer.lock.withLock({ transfer.done }), Date() < transferDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check("main-thread work inherits the peer and observes in-flight caller cancellation",
              transfer.lock.withLock { transfer.done && transfer.passed })
        check("main-thread request scope is restored after cancellation", RequestRuntime.peerPID == nil)
        print("\(passed) input/runtime checks passed")
    }
}
