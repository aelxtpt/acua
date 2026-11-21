import AppKit
import ApplicationServices
import Foundation

private final class NativePasteValuesProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "before"
    private var masks: [Set<String>] = []
    private var errors: [String] = []
    var failRead = false
    func set(_ string: String) { lock.withLock { value = string } }
    func batch(_ keys: Set<String>) throws -> [String:ControllerNativeAXValue] {
        try lock.withLock {
            masks.append(keys)
            if failRead { throw ControllerNativeElementDecoding.Failure.missingResponse }
            var range = CFRange(location:0,length:0)
            return ["AXValue":.init(raw:value as NSString), "AXNumberOfCharacters":.init(raw:NSNumber(value:value.utf16.count)),
                "AXSelectedTextRange":.init(raw:AXValueCreate(.cfRange,&range)!)]
        }
    }
    func log(_ name: String) { lock.withLock { errors.append(name) } }
    var calls: [Set<String>] { lock.withLock { masks } }
    var logged: [String] { lock.withLock { errors } }
    var io: ControllerNativeElementContext.IO {
        .init(supported:{ _ in preconditionFailure("Use cached supported attributes") },batch:{ _,keys in try self.batch(keys) },
            read:{ _,_ in preconditionFailure("Use fresh multiple-attribute reads") })
    }
}

@MainActor enum NativePasteObservationChecks {
    static func fixture(_ directory: URL) async throws {
        let panel = NSPanel(contentRect:.init(x:12,y:12,width:50,height:50),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = false; panel.alphaValue = 0.001; panel.ignoresMouseEvents = true; panel.orderFront(nil)
        defer { panel.close() }
        try String(getpid()).write(to:directory.appendingPathComponent("ready"),atomically:true,encoding:.utf8)
        var previous: String?
        for _ in 0..<800 {
            let command = try? String(contentsOf:directory.appendingPathComponent("command"),encoding:.utf8)
            if command == "stop" { return }
            if let command, command != previous {
                NSAccessibility.post(element:panel,notification:command.hasPrefix("selection") ? .selectedTextChanged:.valueChanged)
                previous = command
            }
            try await Task.sleep(for:.milliseconds(5))
        }
    }

    static func run(output: URL, fixture: URL, directory: URL) async throws -> Int32 {
        var checks: [[String:Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name":name,"passed":value]); if !value { print("FAIL: "+name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let child = Process(); child.executableURL = fixture; child.arguments = ["--paste-observation-fixture",directory.path]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) { try await Task.sleep(for:.milliseconds(5)) }
        guard child.isRunning, FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) else { return 2 }
        let probe = NativePasteValuesProbe()
        let app = SettingsNativeAXElement(element:AXUIElementCreateApplication(child.processIdentifier))
        let node = ControllerNativeElementContext.Node(element:app,snapshot:.init(supported:["AXValue","AXNumberOfCharacters","AXSelectedTextRange","AXTitle"],values:["AXValue":.init(raw:"stale cached value" as NSString)],requested:["AXValue"]))
        let observation = try ControllerNativePasteObservation(pid:child.processIdentifier,focused:node,io:probe.io,logRegistrationError:{ name,_ in probe.log(name) })
        defer { observation.stop() }
        check("native observation filters ordered mask from captured supported attributes", observation.keys == ["AXSelectedTextRange","AXNumberOfCharacters","AXValue"] && probe.calls == [Set(observation.keys)])
        check("native initial values are fresh and retain raw CF representations", observation.initialValues?["AXValue"]?.raw as? String == "before" && observation.initialValues?["AXSelectedTextRange"].map { CFGetTypeID($0.raw) == AXValueGetTypeID() } == true)
        check("both paste notifications register on owned native application", observation.hasObserver && probe.logged.isEmpty)
        let board = NSPasteboard.withUniqueName(); precondition(board.name != NSPasteboard.general.name)
        defer { board.releaseGlobally() }
        board.clearContents(); _ = board.setString("saved owned data",forType:.string)
        var ownershipLosses = 0
        let transaction = ControllerPasteboardTransaction(backend:observation.pasteboardBackend(board,logOwnershipLost:{ ownershipLosses += 1 }))
        let saved = transaction.snapshot()
        let session = try transaction.prepare([.init(type:NSPasteboard.PasteboardType.string.rawValue,data:Data("paste bytes".utf8))])
        observation.markDispatched()
        check("dispatch timestamp is established before real promised read", observation.state.snapshot.dispatchAt != nil && observation.state.snapshot.reads.isEmpty)
        check("owned native clipboard supplies actual promised bytes", board.pasteboardItems?.first?.data(forType:.string) == Data("paste bytes".utf8))
        let read = observation.state.snapshot
        check("native provider feeds distinct start end and success into observation", read.activeReadCount == 0 && read.reads.count == 1 && read.reads[0].succeeded && read.reads[0].end.map { $0 >= read.reads[0].start } == true)
        probe.set("after")
        let poll = observation.acknowledgementPoll { transaction.restore(session) }
        let first = try await poll.poll()
        check("fresh hosted AX change correlates with native read but stays pending", first == nil && observation.state.snapshot.quietDeadline != nil && probe.calls.count == 2)
        try await Task.sleep(for:.milliseconds(110))
        let ready = try await poll.poll()
        check("stable native acknowledgement restores the saved owned clipboard", ready == true && transaction.snapshot() == saved && ownershipLosses == 0)
        check("ready restoration skips fresh AX reread", probe.calls.count == 2 && session.provider.rearming.state == nil)

        // Standard AppKit posts from the owned target exercise the exact two
        //subscriptions. They do not synthesize mouse, key or AX set-value input.
        let start = SuspendingClock.now
        observation.state.withState { $0.readStarted(at:start) }
        try "selection-first".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<100 where observation.state.snapshot.reads.last?.pendingEdit == nil { try await Task.sleep(for:.milliseconds(5)) }
        let selected = observation.state.snapshot.reads.last?.pendingEdit
        check("real selected-text notification updates in-flight paste read", selected != nil)
        try "value-second".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<100 where observation.state.snapshot.reads.last?.pendingEdit == selected { try await Task.sleep(for:.milliseconds(5)) }
        let edited = observation.state.snapshot.reads.last?.pendingEdit
        check("real value notification advances correlated edit timestamp", selected != nil && edited.map { $0 > selected! } == true)
        observation.state.withState { $0.readFinished(start:start,end:SuspendingClock.now,succeeded:true) }
        observation.stop()
        try await Task.sleep(for:.milliseconds(30))
        let stopped = observation.state.snapshot.reads.last?.pendingEdit
        try "selection-after-stop".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        try await Task.sleep(for:.milliseconds(80))
        check("stopped observer receives no later owned edit", observation.state.snapshot.reads.last?.pendingEdit == stopped)
        let noFocus = try ControllerNativePasteObservation(pid:child.processIdentifier,focused:nil,io:probe.io,logRegistrationError:{ name,_ in probe.log(name) })
        let missing = try await noFocus.acknowledgementPoll(restore:{ true }).poll(); noFocus.stop()
        check("absent focused node preserves nil initial snapshot and skips fresh reads", noFocus.initialValues == nil && noFocus.keys.isEmpty && missing == nil && probe.calls.count == 2)
        let failing = NativePasteValuesProbe(); failing.failRead = true
        let failedInitial = try ControllerNativePasteObservation(pid:child.processIdentifier,focused:node,io:failing.io,logRegistrationError:{ name,_ in failing.log(name) })
        failing.failRead = false
        let failedInitialPoll = try await failedInitial.acknowledgementPoll(restore:{ true }).poll()
        failedInitial.stop()
        check("hosted initial read error becomes nil and disables polling but still observes", failedInitial.initialValues == nil && failedInitial.hasObserver && failedInitialPoll == nil && failing.calls.count == 1 && failing.logged.isEmpty && transaction.snapshot() == saved)
        try "stop".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<200 where child.isRunning { try await Task.sleep(for:.milliseconds(5)) }
        check("owned nonactivating AX fixture exits and preserves foreground", !child.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && NSApp == nil)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":checks,"actual_owned_named_clipboard_and_native_AX_notifications":true,"AXTrusted":AXIsProcessTrusted(),"target_terminal":!child.isRunning,"foreground_unchanged":NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,"general_clipboard_transaction_executed":false,"actual_input_focus_or_screen_capture_executed":false,"whole_native_paste_engine_implemented":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native paste observation: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0:3
    }
}
