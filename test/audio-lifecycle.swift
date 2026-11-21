import Foundation

@main enum AudioLifecycleTests {
    static func main() throws {
        func check(_ name: String, _ value: Bool) { precondition(value, name); print("PASS \(name)") }
        func reject(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) }
            catch { check(name, true) }
        }
        // Recorder failures keep their metadata and convert to the socket error envelope.
        let nativeFailures: [(AudioRecorder.Failure, String)] = [
            (.invalidDuration, "invalidDuration"), (.noActiveRecording, "noActiveRecording"),
            (.noDisplay, "noDisplay"), (.recordingAlreadyActive, "recordingAlreadyActive"),
            (.recordingNotOwned, "recordingNotOwned")]
        for (failure, message) in nativeFailures {
            let response = failure.socketError
            check("audio error keeps its code and message: \(message)",
                  response.code == .unknownError && response.message == "Computer Use server error -10005: " + message)
        }
        let decoder = JSONDecoder()
        for json in ["{}", #"{"maxDurationMilliseconds":null}"#] {
            let request = try decoder.decode(AudioRecorder.StartRequest.self, from: Data(json.utf8))
            check("absent or null duration defaults to 60000", try request.duration() == 60_000)
        }
        for json in [#"{"maxDurationMilliseconds":"100"}"#, #"{"maxDurationMilliseconds":true}"#, #"{"maxDurationMilliseconds":100.5}"#] {
            reject("non-integer wire duration is rejected") {
                _ = try decoder.decode(AudioRecorder.StartRequest.self, from: Data(json.utf8))
            }
        }
        for value in [100, 300_000] {
            check("audio duration accepts boundary \(value)", try AudioRecorder.StartRequest(maxDurationMilliseconds: value).duration() == value)
        }

        let finished = DispatchSemaphore(value: 0)
        let fileManager = FileManager.default
        var files: [URL] = []
        defer { for url in files { try? fileManager.removeItem(at: url) } }
        var failStart = false
        let recorder = AudioRecorder { url in
            files.append(url)
            try Data("fixture".utf8).write(to: url)
            if failStart { throw CocoaError(.fileWriteUnknown) }
            return { finished.signal() }
        }
        let first = AudioRecorder.Owner(sessionID: "first", senderPID: 1)
        let sameSession = AudioRecorder.Owner(sessionID: "first", senderPID: 2)
        let otherSession = AudioRecorder.Owner(sessionID: "other", senderPID: 1)
        let local = AudioRecorder.Owner(sessionID: nil, senderPID: 1)
        let otherProcess = AudioRecorder.Owner(sessionID: nil, senderPID: 2)
        for value in [-1, 99, 300_001, Int.max] {
            reject("out of range duration \(value) is rejected before opening a file") {
                try recorder.start(.init(maxDurationMilliseconds: value), owner: first)
            }
        }
        check("invalid audio requests allocate no file", files.isEmpty)
        try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: first)
        reject("a concurrent Start cannot replace an active recording") { try recorder.start(.init(), owner: first) }
        reject("another session from the same process cannot claim the file") { _ = try recorder.stop(owner: otherSession) }
        reject("a process with no session cannot claim a session-owned file") { _ = try recorder.stop(owner: local) }
        check("the same session can claim from a different process", try recorder.stop(owner: sameSession) == files[0])
        check("manual Stop closes the writer", finished.wait(timeout: .now() + 1) == .success)
        reject("a recording can be claimed only once") { _ = try recorder.stop(owner: first) }

        try recorder.start(.init(maxDurationMilliseconds: 100), owner: local)
        check("automatic Stop closes the writer", finished.wait(timeout: .now() + 2) == .success)
        reject("only the owning process can claim a recording without a session") { _ = try recorder.stop(owner: otherProcess) }
        check("Stop returns the auto-stopped file", try recorder.stop(owner: local) == files[1] && fileManager.fileExists(atPath: files[1].path))
        check("claiming an auto-stopped file does not stop the writer twice", finished.wait(timeout: .now()) == .timedOut)

        try recorder.start(.init(maxDurationMilliseconds: 100), owner: first)
        check("a second recording can also stop automatically", finished.wait(timeout: .now() + 2) == .success)
        try recorder.start(.init(maxDurationMilliseconds: 300_000), owner: first)
        check("a new Start deletes the unclaimed auto-stopped file", !fileManager.fileExists(atPath: files[2].path))
        _ = try recorder.stop(owner: first)

        failStart = true
        reject("backend start failure is returned") { try recorder.start(.init(), owner: first) }
        check("backend start failure discards the partial output", !fileManager.fileExists(atPath: files[4].path))
        failStart = false
        try recorder.start(.init(), owner: first)
        check("Start can retry after a failed backend", try recorder.stop(owner: first) == files[5])
        for _ in 0..<2 { precondition(finished.wait(timeout: .now() + 1) == .success) }

        let turnOwner = AudioRecorder.Owner(sessionID: "first", senderPID: 1, turnID: "capture-turn")
        try recorder.start(.init(), owner: turnOwner)
        recorder.discardEndedTurn(threadID: "other", turnID: "capture-turn")
        recorder.discardEndedTurn(threadID: "first", turnID: "another-turn")
        check("ending a different thread or turn leaves the writer and file active",
              finished.wait(timeout: .now()) == .timedOut && fileManager.fileExists(atPath: files[6].path))
        recorder.discardEndedTurn(threadID: "first", turnID: "capture-turn")
        check("ending the owning turn closes and removes the recording",
              finished.wait(timeout: .now()) == .success && !fileManager.fileExists(atPath: files[6].path))
        recorder.discardEndedTurn(threadID: "first", turnID: "capture-turn")
        check("duplicate turn ending does not close the writer again", finished.wait(timeout: .now()) == .timedOut)
        reject("an ended turn no longer has an unclaimed file") { _ = try recorder.stop(owner: first) }

        try recorder.start(.init(maxDurationMilliseconds: 100), owner: turnOwner)
        precondition(finished.wait(timeout: .now() + 2) == .success)
        recorder.discardEndedTurn(threadID: "first", turnID: nil)
        check("ending a thread without a turn ID deletes its auto-stopped file",
              !fileManager.fileExists(atPath: files[7].path) && finished.wait(timeout: .now()) == .timedOut)

        try recorder.start(.init(), owner: first)
        recorder.discardEndedTurn(threadID: "first", turnID: "capture-turn")
        check("an owner without a turn ID is matched by thread alone",
              finished.wait(timeout: .now()) == .success && !fileManager.fileExists(atPath: files[8].path))

        try recorder.start(.init(), owner: local)
        recorder.discardEndedTurn(threadID: "first", turnID: nil)
        check("turn ending cannot discard audio owned only by PID", try recorder.stop(owner: local) == files[9])
        recorder.discardEndedTurn(threadID: "first", turnID: nil)
        check("turn ending leaves already delivered files alone", fileManager.fileExists(atPath: files[5].path))

        var endedDuringStart = false
        var closedDuringStart = false
        let racingRecorder = AudioRecorder { url in
            files.append(url)
            try Data("fixture".utf8).write(to: url)
            endedDuringStart = true
            return { closedDuringStart = true }
        }
        reject("a turn ending during capture setup cancels Start") {
            try RequestRuntime.withCheckpoint({
                if endedDuringStart { throw ServiceError(.agentTurnAlreadyEnded, "Fixture ended") }
            }) {
                try racingRecorder.start(.init(), owner: turnOwner)
            }
        }
        check("a cancelled Start closes capture and removes its partial file",
              closedDuringStart && !fileManager.fileExists(atPath: files[10].path))
        try AudioBridgeTests.run()
    }
}
