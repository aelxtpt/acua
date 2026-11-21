import Foundation

enum AudioBridgeTests {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
    }
    private final class Gate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        private var value: Value?
        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let value { lock.unlock(); continuation.resume(returning: value) }
                else { self.continuation = continuation; lock.unlock() }
            }
        }
        func open(_ value: Value) {
            lock.lock(); self.value = value
            let continuation = continuation; self.continuation = nil
            lock.unlock(); continuation?.resume(returning: value)
        }
    }

    static func run() throws {
        func check(_ name: String, _ condition: Bool) { precondition(condition, name); print("PASS audio bridge: \(name)") }
        func wait(_ signal: DispatchSemaphore, _ name: String) {
            check(name, signal.wait(timeout: .now() + 3) == .success)
        }
        func deadline<T>(_ milliseconds: Double, _ body: () throws -> T) throws -> T {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": Date().timeIntervalSince1970 * 1000 + milliseconds], body: body)
        }
        func expires(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) }
            catch let error as ServiceError { check(name, error.message == "Request deadline exceeded") }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let finishes = Box(0)
        let bridge = try AudioCaptureBridge.start(begin: { 7 }, finish: { value in
            precondition(value == 7); finishes.update { $0 += 1 }
        })
        try bridge.stop(); try bridge.stop()
        check("successful repeated Stop closes one resource once", finishes.read() == 1)

        do {
            let disposed = DispatchSemaphore(value: 0), abandoned = Box(0)
            var unclaimed: AudioCaptureBridge<Int>? = try AudioCaptureBridge.start(begin: { 11 }, finish: { value in
                precondition(value == 11); disposed.signal()
            }, abandon: { abandoned.update { $0 += 1 } })
            precondition(unclaimed != nil)
            unclaimed = nil
            check("dropping an unclaimed start closes its output", abandoned.read() == 1)
            wait(disposed, "dropping an unclaimed start disposes its resource asynchronously")
        }

        let startedExpired = Box(false)
        expires("expired Start does not invoke native setup") {
            _ = try RequestRuntime.withRequest(["deadlineUnixMilliseconds": 0]) {
                try AudioCaptureBridge.start(begin: { startedExpired.update { $0 = true }; return 1 }, finish: { _ in })
            }
        }
        check("expired Start created no resource", !startedExpired.read())

        do {
            let gate = Gate<Int>(), entered = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
            let disposed = DispatchSemaphore(value: 0), cancelled = Box(false), outcomes = Box([String]())
            let disposeCount = Box(0), abandoned = Box(0)
            DispatchQueue.global().async {
                defer { returned.signal() }
                do {
                    _ = try RequestRuntime.withRequest([:], cancelled: { cancelled.read() }) {
                        try AudioCaptureBridge.start(begin: { entered.signal(); return await gate.wait() }, finish: { value in
                            precondition(value == 19); disposeCount.update { $0 += 1 }; disposed.signal()
                        }, abandon: { abandoned.update { $0 += 1 } })
                    }
                    outcomes.update { $0.append("unexpected success") }
                } catch let error as ServiceError { outcomes.update { $0.append(error.message) } }
                catch { outcomes.update { $0.append(String(describing: error)) } }
            }
            wait(entered, "delayed Start reached the controlled provider")
            cancelled.update { $0 = true }
            wait(returned, "cancelled Start returns before its provider completes")
            check("cancelled Start returns its cancellation error", outcomes.read() == ["Request cancelled"])
            check("no resource is disposed before its late arrival", disposeCount.read() == 0)
            check("cancelled setup closes its output before a late stream arrives", abandoned.read() == 1)
            gate.open(19)
            wait(disposed, "late successful Start is stopped after abandonment")
            check("abandoned resource is disposed once", disposeCount.read() == 1)
        }

        do {
            let gate = Gate<Int>(), disposed = DispatchSemaphore(value: 0), begun = DispatchSemaphore(value: 0)
            expires("Start deadline bounds an unresponsive provider") {
                _ = try deadline(80) {
                    try AudioCaptureBridge.start(begin: { begun.signal(); return await gate.wait() }, finish: { _ in disposed.signal() })
                }
            }
            wait(begun, "deadline test actually began provider work")
            gate.open(23)
            wait(disposed, "deadline-abandoned Start also disposes its late resource")
        }

        let owner = AudioRecorder.Owner(sessionID: "bounded-audio-fixture", senderPID: 1)
        let files = Box([URL]())
        defer { for file in files.read() { try? FileManager.default.removeItem(at: file) } }

        do {
            let gate = Gate<Bool>(), closed = DispatchSemaphore(value: 0), finishCount = Box(0), abandoned = Box(0)
            let deliveredURLs = Box([URL]())
            let recorder = AudioRecorder(onFileDelivered: { url in deliveredURLs.update { $0.append(url) } }) { url in
                files.update { $0.append(url) }; try Data("owned writer fixture".utf8).write(to: url)
                let bridge = try AudioCaptureBridge.start(begin: { 29 }, finish: { _ in
                    finishCount.update { $0 += 1 }; closed.signal(); _ = await gate.wait()
                }, abandon: { abandoned.update { $0 += 1 } })
                return { try bridge.stop() }
            }
            try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: owner)
            var delivered = false
            expires("Stop deadline returns while native completion is pending") {
                try deadline(80) { _ = try recorder.stop(owner: owner); delivered = true }
            }
            wait(closed, "Stop initiated resource cleanup before waiting")
            check("an unfinished Stop exposes no audio URL", !delivered && deliveredURLs.read().isEmpty)
            let file = try deadline(1000) { try recorder.stop(owner: owner) }
            delivered = true
            check("reentrant Stop follows the consumed-stream branch", file == files.read().last && deliveredURLs.read() == [file])
            check("reentrant claims never stop the pending resource twice", finishCount.read() == 1 && delivered)
            check("timed-out Stop requests close abandoned output only once", abandoned.read() == 1)
            gate.open(true)
            do { _ = try recorder.stop(owner: owner); preconditionFailure("Audio claimed a third time") }
            catch AudioRecorder.Failure.noActiveRecording {
                check("completed metadata claim rejects later Stop requests", true)
            }
            check("successful retry reused the native operation", finishCount.read() == 1)
        }

        do {
            let finishCount = Box(0)
            let recorder = AudioRecorder { url in
                files.update { $0.append(url) }; try Data("owned failure fixture".utf8).write(to: url)
                let bridge = try AudioCaptureBridge.start(begin: { 31 }, finish: { _ in
                    finishCount.update { $0 += 1 }; throw NSError(domain: "OwnedAudioStop", code: 41)
                })
                return { try bridge.stop() }
            }
            try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: owner)
            do { _ = try recorder.stop(owner: owner); preconditionFailure("Stop swallowed its native error") }
            catch { check("Stop propagates the native error", (error as NSError).domain == "OwnedAudioStop" && (error as NSError).code == 41) }
            do { try recorder.start(.init(), owner: owner); preconditionFailure("Failed Stop was mistaken for auto-stop") }
            catch AudioRecorder.Failure.recordingAlreadyActive { check("failed manual Stop retains URL ownership", true) }
            let file = try deadline(1000) { try recorder.stop(owner: owner) }
            check("retry after native Stop failure claims its finalized file", file == files.read().last && finishCount.read() == 1)
        }

        do {
            let failed = DispatchSemaphore(value: 0), finishCount = Box(0)
            let recorder = AudioRecorder { url in
                let first=finishCount.read()==0
                files.update { $0.append(url) }; try Data("owned auto-stop fixture".utf8).write(to: url)
                let bridge = try AudioCaptureBridge.start(begin: { 37 }, finish: { _ in
                    finishCount.update { $0 += 1 }
                    if first { failed.signal(); throw NSError(domain: "OwnedAutoStop", code: 43) }
                })
                return { try bridge.stop() }
            }
            try recorder.start(.init(maxDurationMilliseconds: 100), owner: owner)
            let done=DispatchSemaphore(value:0)
            Task.detached {
                let limit=ContinuousClock.now.advanced(by:.seconds(2))
                var stopped=false
                repeat {
                    let optional=Mirror(reflecting:recorder).children.first(where:{$0.label=="recording"})!.value
                    let record=Mirror(reflecting:optional).children.first?.value
                    stopped=record.flatMap{Mirror(reflecting:$0).children.first(where:{$0.label=="didAutoStop"})?.value as? Bool} ?? false
                    if stopped {break}
                    try? await Task.sleep(for:.milliseconds(2))
                } while ContinuousClock.now<limit
                precondition(stopped)
                done.signal()
            }
            let oldFile=files.read().last!
            wait(failed, "automatic Stop reached its failing native provider")
            wait(done, "automatic Stop error completes its state transition")
            // A failed automatic Stop still resumes the recorder, so Start works again.
            try deadline(1000) {try recorder.start(.init(),owner:owner)}
            check("failed automatic Stop permits replacement and deletes its old file",
                  !FileManager.default.fileExists(atPath:oldFile.path) && finishCount.read()==1)
            let file=try deadline(1000) {try recorder.stop(owner:owner)}
            check("replacement after automatic Stop failure owns its own native resource",
                  file==files.read().last && finishCount.read()==2)
        }

        do {
            let gate = Gate<Int>(), began = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
            let disposed = DispatchSemaphore(value: 0), cancelled = Box(false), outcomes = Box([String]())
            let recorder = AudioRecorder { url in
                files.update { $0.append(url) }; try Data("owned lock fixture".utf8).write(to: url)
                let bridge = try AudioCaptureBridge.start(begin: { began.signal(); return await gate.wait() }, finish: { _ in disposed.signal() })
                return { try bridge.stop() }
            }
            DispatchQueue.global().async {
                defer { returned.signal() }
                do { try RequestRuntime.withRequest([:], cancelled: { cancelled.read() }) { try recorder.start(.init(), owner: owner) } }
                catch let error as ServiceError { outcomes.update { $0.append(error.message) } }
                catch { outcomes.update { $0.append(String(describing: error)) } }
            }
            wait(began, "first audio request holds setup ownership")
            let claimed=try deadline(50) {try recorder.stop(owner:owner)}
            check("Stop claims the published URL while initial setup is pending", claimed==files.read().last)
            cancelled.update { $0 = true }
            wait(returned, "cancelled setup releases recorder ownership")
            check("failed setup removes the partial output", !FileManager.default.fileExists(atPath: files.read().last!.path))
            gate.open(47)
            wait(disposed, "cancelled recorder setup disposes its late native resource")
            check("setup returns cancellation rather than success", outcomes.read() == ["Request cancelled"])
        }

        check("delivered file lifetime is 30 seconds", AudioRecorder.deliveredFileLifetime == .seconds(30))
        do {
            let deliveredURLs = Box([URL]()), finished = DispatchSemaphore(value: 0)
            let recorder = AudioRecorder(onFileDelivered: { url in deliveredURLs.update { $0.append(url) } }) { url in
                files.update { $0.append(url) }; try Data("owned file retention fixture".utf8).write(to: url)
                return { finished.signal() }
            }
            try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: owner)
            check("an active recording is not scheduled for delivered-file deletion", deliveredURLs.read().isEmpty)
            let delivered = try recorder.stop(owner: owner)
            wait(finished, "retention fixture closes its writer before delivering")
            check("successful Stop transfers its own URL to retention", deliveredURLs.read() == [delivered])
            do { _ = try recorder.stop(owner: owner); preconditionFailure("Duplicate audio claim") }
            catch AudioRecorder.Failure.noActiveRecording {
                check("a rejected duplicate claim schedules no second deletion", deliveredURLs.read().count == 1)
            }
            AudioRecorder.scheduleDeliveredFileDeletion(delivered, after: .milliseconds(40))
            let limit = ContinuousClock.now.advanced(by: .seconds(2))
            while FileManager.default.fileExists(atPath: delivered.path) && ContinuousClock.now < limit { try RequestRuntime.wait(0.01) }
            check("scheduled retention expiration removes the file", !FileManager.default.fileExists(atPath: delivered.path))
            try recorder.start(.init(maxDurationMilliseconds: 100), owner: owner)
            wait(finished, "unclaimed retention fixture stops automatically")
            try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: owner)
            check("replacing unclaimed automatic output is not a delivery", deliveredURLs.read().count == 1)
            _ = try recorder.stop(owner: owner)
            wait(finished, "replacement retention fixture closes normally")
            try recorder.start(.init(), owner: owner)
            recorder.discardEndedTurn(threadID: "bounded-audio-fixture", turnID: nil)
            wait(finished, "turn-ending retention fixture closes normally")
            check("discarding an ended turn does not schedule delivered-file retention", deliveredURLs.read().count == 2)
        }
    }
}
