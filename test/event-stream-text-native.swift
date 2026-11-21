import AppKit
import ApplicationServices

@MainActor private struct NoURLPolicy: EventStreamRecordFilter {
    func disposition(for record: EventStreamRecord) async -> EventStreamRecordDisposition {
        fatalError("This native fixture has no URL; a URL policy backend was not supplied")
    }
}

@main enum EventStreamNativeTextTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ label: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(label)") }
        checks += 1; print("PASS: \(label)")
    }
    @MainActor static func pumpWorkspaceNotifications() {
        // Async main does not run AppKit's event loop. NSWorkspace and
        // NSRunningApplication activation state is updated by these sources.
        _ = RunLoop.main.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))
    }
    @MainActor static func until(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw NSError(domain:"NativeTextFixture",code:1,userInfo:[NSLocalizedDescriptionKey:label]) }
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    static func events(_ directory: URL) -> [[String:Any]] {
        guard let text = try? String(contentsOf:directory.appendingPathComponent("events.jsonl"),encoding:.utf8) else { return [] }
        return text.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
    }
    @MainActor static func command(_ value: String, directory: URL, response: String) async throws -> [String:Any] {
        let count = events(directory).count
        try value.write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        var result: [String:Any]?
        try await until("Fixture did not respond to \(value)") {
            result = events(directory).dropFirst(count).first { $0["event"] as? String == response }
            return result != nil
        }
        return result!
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args=CommandLine.arguments
        guard args.count == 4, let pid=Int32(args[1]), let window=UInt32(args[2]),
              let ownedApplication=NSRunningApplication(processIdentifier:pid),
              ownedApplication.bundleIdentifier == "test.acua.event-stream-text-fixture" else {
            fatalError("Only the owned disposable EventStream text fixture is accepted")
        }
        let directory=URL(fileURLWithPath:args[3])
        guard AXIsProcessTrusted() else { fatalError("Native recorder test requires Accessibility") }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            fputs("Native recorder fixture requires an unlocked macOS session.\n", stderr)
            exit(2)
        }
        // A ready window is not an activation barrier. Launch-time activation
        // can lose to the app finishing launch or another fixture's shutdown.
        // Request activation only for the validated disposable app, then keep
        // the existing foreground/menu-owner guard before any global input.
        var setup:[[String:Any]]=[]
        func recordSetup(_ phase:String,_ accepted:Bool?=nil) {
            var state:[String:Any] = ["phase":phase,"expectedPID":pid,
                "foregroundPID":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "menuOwnerPID":NSWorkspace.shared.menuBarOwningApplication?.processIdentifier ?? -1,
                "fixtureIsActive":ownedApplication.isActive,"timestamp":Date().timeIntervalSince1970]
            if let accepted {state["activationAccepted"]=accepted}
            setup.append(state)
            if let bytes=try? JSONSerialization.data(withJSONObject:setup,options:[.prettyPrinted,.sortedKeys]) {
                try? bytes.write(to:directory.appendingPathComponent("recorder-activation.json"),options:.atomic)
            }
        }
        if ProcessInfo.processInfo.environment["CUA_TEST_RECORDER_START_DEACTIVATED"] == "1" {
            guard let rawPID=ProcessInfo.processInfo.environment["CUA_TEST_RECORDER_OTHER_OWNED_PID"],let otherPID=Int32(rawPID),
                  let other=NSRunningApplication(processIdentifier:otherPID),
                  other.bundleIdentifier=="test.acua.event-stream-text-decoy" else {
                throw NSError(domain:"NativeTextFixture",code:2,userInfo:[NSLocalizedDescriptionKey:"Only the second owned disposable fixture may establish background-start coverage"])
            }
            recordSetup("other-owned-activation-requested",other.activate(options:[]))
            try await until("Second owned fixture did not become foreground/menu owner") {
                pumpWorkspaceNotifications()
                return NSWorkspace.shared.frontmostApplication?.processIdentifier==otherPID && NSWorkspace.shared.menuBarOwningApplication?.processIdentifier==otherPID
            }
            recordSetup("background-start-established")
        }
        pumpWorkspaceNotifications()
        recordSetup("before")
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid || NSWorkspace.shared.menuBarOwningApplication?.processIdentifier != pid {
            recordSetup("activation-requested",ownedApplication.activate(options:[]))
            _ = try await command("request-key-focus",directory:directory,response:"requested-key-focus")
        }
        do {
            try await until("Fixture is not foreground/menu owner; see recorder-activation.json") {
                pumpWorkspaceNotifications()
                return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == pid
            }
        } catch {recordSetup("failed");throw error}
        recordSetup("ready")
        let initial=try await command("state",directory:directory,response:"state")
        check("owned fixture is active before global input", initial["isActive"] as? Bool == true && initial["frontmostPID"] as? Int32 == pid)
        let context=EventStreamNativeContext(), applicationResolver=EventStreamApplicationResolver()
        check("native foreground tracker resolves fixture menu owner", context.backend.trackedFrontmostProcessIdentifier == pid)
        let writer=try EventStreamJSONLWriter(sessionID:"native-recording",rootDirectoryURL:directory)
        defer { writer.close() }
        let processor=EventStreamRecordProcessor(writer:writer,filter:NoURLPolicy(),resolveApplication:applicationResolver.resolve)
        var records: [EventStreamRecord] = [], observations: [EventStreamInputObservation] = [], sequence=0
        let builder=context.makeInputBuilder(nextIdentity:{sequence += 1;return .init(id:sequence,timestamp:Date())},
            isRecording:{true},fallbackProcessIdentifier:{pid},shouldCaptureApplication:{$0.processIdentifier == pid},
            emitText:{record in records.append(record);processor.receive(record)},
            prepare:{_ in fatalError("Only native text is injected by this fixture")})
        let tap=EventStreamInputTap()
        defer { tap.stop();builder.discardPendingInput() }
        try tap.start(windowOwner:{context.backend.window($0)?.processIdentifier}) { event in
            guard event.type == .keyDown, event.target.processIdentifier == pid else { return }
            observations.append(event);builder.receive(event)
        }
        check("real annotated-session input tap is installed", tap.isInstalled)
        _ = try await command("event-stream-text",directory:directory,response:"event-stream-text-posted")
        try await until("Native key did not reach recorder") { records.count == 1 }
        let current=try await command("state",directory:directory,response:"state")
        check("listen-only tap preserves actual fixture Unicode insertion", (current["text"] as? String)?.replacingOccurrences(of:"á😀",with:"") == initial["text"] as? String && (current["text"] as? String) != initial["text"] as? String)
        check("native observation carries actual key characters", observations.count == 1 && observations[0].characters == "á😀")
        check("native key resolves fixture PID and window", observations[0].target.processIdentifier == pid && records[0].window?.windowID == window)
        check("native debounce emits text with its sequence semantics", records[0].kind == .keyboardTextInput && records[0].keyboard?.text == "á😀" && records[0].id == 2)
        check("native descriptor refresh reads real edited AXTextArea", records[0].keyboard?.target?.role == "AXTextArea" && records[0].keyboard?.target?.value?.contains("á😀") == true)
        check("native text context retains actual fixture metadata", records[0].app?.processIdentifier == pid && records[0].app?.bundleIdentifier == "test.acua.event-stream-text-fixture")
        let lines=try String(contentsOf:writer.eventsURL,encoding:.utf8).split(separator:"\n")
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let stored=try decoder.decode(EventStreamRecord.self,from:Data(lines[0].utf8))
        check("native event passes through processor into real JSONL", lines.count == 1 && stored.id == records[0].id && stored.keyboard == records[0].keyboard && stored.app == records[0].app)
        let count=observations.count
        tap.stop();builder.discardPendingInput()
        _ = try await command("event-stream-text",directory:directory,response:"event-stream-text-posted")
        try await Task.sleep(for:.milliseconds(100))
        let afterStop=try await command("state",directory:directory,response:"state")
        check("stopping tap removes delivery while input still reaches fixture", !tap.isInstalled && observations.count == count && (afterStop["text"] as? String)?.components(separatedBy:"á😀").count == 3)
        check("stopped source cannot append a late text record", records.count == 1 && builder.pendingInteractionCount == 0)
        print("EVENT STREAM NATIVE TEXT: \(checks) checks passed; artifacts: \(directory.path)")
    }
}
