import AppKit
import ApplicationServices
import Foundation

enum OwnedPasteFailure: Error { case send }
final class OwnedPasteLogs: @unchecked Sendable {
    private let lock = NSLock(); private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    var snapshot: [String] { lock.withLock { names } }
}
@MainActor final class OwnedPasteLedger {
    var active = 0, maximum = 0
    var starts: [String] = [], finishes: [String] = []
}

///The send boundary is intercepted deliberately. Clipboard provider reads,
///stream cancellation, AX delivery, polling and restoration are actual native
///operations on owned resources; physical input/activation is not executed.
@MainActor final class OwnedPasteBackend: ControllerPasteEngineBackend {
    enum Mode { case read, richRead, unread, providerFailure, ownershipLost, sendFailure }
    typealias Observation = ControllerNativePasteObservation
    typealias Transaction = ControllerPasteboardTransaction<ControllerNativePasteboardBackend>
    @MainActor final class Session {
        let transaction: Transaction
        let clipboard: Transaction.Session
        init(_ transaction: Transaction,_ clipboard: Transaction.Session) { self.transaction = transaction; self.clipboard = clipboard }
    }
    let board: NSPasteboard
    let pid: Int32
    let directory: URL
    let mode: Mode
    let label: String
    let ledger: OwnedPasteLedger
    let logs = OwnedPasteLogs()
    var events: [String] = [], received: Data?, session: Session?
    var receivedRepresentations: [String:Data] = [:]
    var observation: Observation?, flag = false, lost = 0, restored = 0
    init(board: NSPasteboard,pid: Int32,directory: URL,mode: Mode,label: String,ledger: OwnedPasteLedger) {
        self.board = board; self.pid = pid; self.directory = directory; self.mode = mode; self.label = label; self.ledger = ledger
    }
    func ensureInitialFocus() throws { events.append("initial-intercept"); ledger.active += 1; ledger.maximum = max(ledger.maximum,ledger.active); ledger.starts.append(label) }
    func observe() throws -> Observation {
        events.append("observe")
        let logs = logs
        let value = try Observation(pid:pid,focused:nil,io:nil,logRegistrationError:{ name,_ in logs.add(name) })
        observation = value; return value
    }
    func stop(_ observation: Observation) { observation.stop(); events.append("stop"); ledger.active -= 1; ledger.finishes.append(label) }
    func prepare(text: String,format: ControllerPasteFormat,observation: Observation) async throws -> Session {
        events.append("prepare")
        let transaction = Transaction(backend:observation.pasteboardBackend(board,logOwnershipLost:{ self.lost += 1 }))
        let values = try await ControllerPasteRendering.native.representations(text:text,format:format)
        let value = Session(transaction,try transaction.prepare(values)); session = value; return value
    }
    func markDispatched(_ observation: Observation) { events.append("dispatch"); observation.markDispatched() }
    func enforceKeyboardFocus() async throws { events.append("focus-intercept") }
    func sendPasteShortcut() async throws {
        events.append("send-intercept")
        if mode == .sendFailure { throw OwnedPasteFailure.send }
        guard let session else { preconditionFailure("Prepared session required") }
        if mode == .providerFailure {
            session.clipboard.provider.pasteboard(board,item:NSPasteboardItem(),provideDataForType:.init("local.cua.unknown"))
        } else if mode != .unread {
            //Give the observer's main-queue registration barrier time to run.
            try await Task.sleep(for:.milliseconds(15))
            received = board.pasteboardItems?.first?.data(forType:.string)
            if mode == .richRead, let item = board.pasteboardItems?.first {
                for type in item.types { receivedRepresentations[type.rawValue] = item.data(forType:type) }
            }
            if mode == .ownershipLost { board.clearContents(); _ = board.setString("new owned writer",forType:.string) }
            else { try ("value-"+UUID().uuidString).write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8) }
        }
    }
    func markNeedsUISettle() { events.append("flag"); flag = true }
    func waitForRead(_ session: Session,timeout: Duration) async throws -> Bool {
        events.append("read"); precondition(timeout == .seconds(2))
        let provider = session.clipboard.provider
        return try await ControllerPasteWaiting.firstRead(timeout:timeout) { var iterator = provider.reads.makeAsyncIterator(); return await iterator.next() != nil }
    }
    func checkCancellation() throws { try Task.checkCancellation() }
    func ownsGeneration(_ session: Session) -> Bool { board.changeCount == session.clipboard.generation }
    func pollAcknowledgement(_ session: Session,observation: Observation,timeout: Double,delay: Double) async throws -> Bool {
        events.append("poll")
        let poll = observation.acknowledgementPoll { self.restored += 1; return session.transaction.restore(session.clipboard) }
        return try await ControllerPasteWaiting.poll(timeout:timeout,delay:delay) { try await poll.poll() }
    }
    func failedToProvideData(_ session: Session) -> Bool { session.clipboard.provider.failedToProvideData }
    func restore(_ session: Session) -> Bool { restored += 1; return session.transaction.restore(session.clipboard) }
}

@MainActor enum NativePasteEngineChecks {
    static func run(output: URL,fixture: URL,directory: URL) async throws -> Int32 {
        var cases: [[String:Any]] = []
        func check(_ name: String,_ value: Bool) { cases.append(["name":name,"passed":value]); if !value { print("FAIL: "+name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let child = Process(); child.executableURL = fixture; child.arguments = ["--paste-observation-fixture",directory.path]
        try child.run(); defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) { try await Task.sleep(for:.milliseconds(5)) }
        guard child.isRunning,FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) else { return 2 }
        let board = NSPasteboard.withUniqueName(); precondition(board.name != NSPasteboard.general.name)
        defer { board.releaseGlobally() }
        func reset() { board.clearContents(); _ = board.setString("owned baseline",forType:.string) }
        reset()
        let ledger = OwnedPasteLedger()
        func backend(_ mode: OwnedPasteBackend.Mode,_ label: String) -> OwnedPasteBackend { .init(board:board,pid:child.processIdentifier,directory:directory,mode:mode,label:label,ledger:ledger) }
        func run(_ value: OwnedPasteBackend) async -> (any Error)? {
            do { try await ControllerPasteEngine(backend:value).paste(text:value.label,format:.text); return nil } catch { return error }
        }
        let normal = backend(.read,"normal 😀"); let normalError = await run(normal)
        check("actual promised read and AX edit acknowledge and restore owned native transaction",normalError == nil && normal.received == Data(normal.label.utf8) && board.string(forType:.string) == "owned baseline" && normal.restored == 1)
        check("native composed observation records successful read and actual AX edit",normal.observation?.state.snapshot.reads.first?.succeeded == true && normal.observation?.state.snapshot.quietDeadline != nil && normal.logs.snapshot.isEmpty)
        check("composed engine marks deferred settle only after intercepted send",normal.flag && normal.events == ["initial-intercept","observe","prepare","dispatch","focus-intercept","send-intercept","flag","read","poll","stop"])
        let unread = backend(.unread,"unread"); let unreadError = await run(unread)
        check("actual two second stream timeout recovers owned clipboard without fabricated read",unreadError == nil && unread.received == nil && unread.observation?.state.snapshot.reads.isEmpty == true && unread.restored == 1 && board.string(forType:.string) == "owned baseline")
        let failed = backend(.providerFailure,"provider-failure"); let failedError = await run(failed)
        check("actual failed provider callback and stream timeout produce data failure",failedError as? ControllerPasteEngineFailure == .failedToProvideData && failed.session?.clipboard.provider.failedToProvideData == true && failed.observation?.state.snapshot.reads.first?.succeeded == false)
        check("data failure restores clipboard and clears rearming before stop",failed.restored == 1 && failed.session?.clipboard.provider.rearming.state == nil && board.string(forType:.string) == "owned baseline" && failed.events.last == "stop")
        let lost = backend(.ownershipLost,"lost"); let lostError = await run(lost)
        check("actual private clipboard ownership change fails without restoring over new writer",lostError as? ControllerPasteEngineFailure == .ownershipLost && board.string(forType:.string) == "new owned writer" && lost.lost == 1 && !lost.events.contains("poll"))
        reset()
        let send = backend(.sendFailure,"send-failure"); let sendError = await run(send)
        check("intercepted send failure preserves identity and restores native transaction",sendError as? OwnedPasteFailure != nil && !send.flag && send.restored == 1 && board.string(forType:.string) == "owned baseline")
        let one = backend(.read,"one"),two = backend(.read,"two")
        let first = Task { try await ControllerGlobalPasteQueue.shared.sync { try await ControllerPasteEngine(backend:one).paste(text:one.label,format:.text) } }
        while !ledger.starts.contains("one") { await Task.yield() }
        let second = Task { try await ControllerGlobalPasteQueue.shared.sync { try await ControllerPasteEngine(backend:two).paste(text:two.label,format:.text) } }
        try await first.value; try await second.value
        check("global queue serializes independent native clipboard engine instances",ledger.maximum == 1 && ledger.starts.suffix(2) == ["one","two"] && ledger.finishes.suffix(2) == ["one","two"] && ledger.active == 0)
        check("serialized native transactions each receive own bytes and restore shared baseline",one.received == Data("one".utf8) && two.received == Data("two".utf8) && board.string(forType:.string) == "owned baseline" && one.restored == 1 && two.restored == 1)
        //Construct the production runtime without invoking its physical input
        //closures. Text rendering is the actual byte path, not a test renderer.
        let fixtureResources = SelectionDataFixture().resources
        let rendering = ControllerPasteRendering(markdownToHTML:{ _ in nil },htmlToRichBytes:{ _ in nil })
        let runtime = ControllerNativePasteRuntime.native(resources:fixtureResources,rendering:rendering)
        let nativeText = try await runtime.representations("real text bytes",.text)
        check("concrete production runtime binds native dependencies and preserves text bytes",nativeText == [.init(type:NSPasteboard.PasteboardType.string.rawValue,data:Data("real text bytes".utf8))])
        try "stop".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<200 where child.isRunning { try await Task.sleep(for:.milliseconds(5)) }
        check("owned native fixture exits without changing foreground or initializing client AppKit",!child.isRunning && foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier && NSApp == nil)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,"actual_owned_clipboard_native_AX_and_global_queue_executed":true,"physical_keyboard_focus_capture_or_general_clipboard_executed":false,"send_boundary_intercepted":true,"target_terminal":!child.isRunning,"native_rich_conversion_implemented":true,"ordinary_native_routes_integrated":false,"full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native paste engine: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0:3
    }
}
