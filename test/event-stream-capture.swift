import AppKit
import Foundation

private final class Recorder: EventStreamCaptureProducing {
    typealias Application = String
    var isRecording = false
    var onRecordStored: ((EventStreamRecord) -> Void)?
    var onSuppressedRecordStored: ((EventStreamRecord) -> Void)?
    var shouldCaptureApplication: ((String) -> Bool)?
    var startCount = 0, flushCount = 0, refreshCount = 0
    var stopFlags: [Bool] = []
    var pending: [EventStreamRecord] = []
    var failStart = false
    var onFlush: (() -> Void)?
    private var id = 0
    enum Failure: Error { case start }
    func makeSessionBoundaryRecord(kind: EventStreamEventKind) -> EventStreamRecord {
        id += 1
        return .init(id: id, timestamp: Date(timeIntervalSince1970: 0), kind: kind)
    }
    func start() throws {
        startCount += 1
        if failStart { throw Failure.start }
        isRecording = true
        id = 0
        onRecordStored?(makeSessionBoundaryRecord(kind: .sessionStarted))
        refreshCurrentApplication()
    }
    func refreshCurrentApplication() {
        refreshCount += 1
        onRecordStored?(makeSessionBoundaryRecord(kind: .windowChanged))
    }
    func flushPendingRecords() {
        flushCount += 1
        let saved = pending; pending = []
        for event in saved { onRecordStored?(event) }
        let callback = onFlush; onFlush = nil; callback?()
    }
    func stop(emitSessionEnded: Bool) {
        stopFlags.append(emitSessionEnded)
        flushPendingRecords()
        if emitSessionEnded { onRecordStored?(makeSessionBoundaryRecord(kind: .sessionEnded)) }
        isRecording = false
    }
    var hasCallbacks: Bool { onRecordStored != nil || onSuppressedRecordStored != nil || shouldCaptureApplication != nil }
}

@main
struct EventStreamCaptureTests {
    static var checks = 0
    static func check(_ name: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    static func main() throws {
        let recorder = Recorder()
        let shared = EventStreamCaptureCoordinator(recorder: recorder)
        var first: [EventStreamRecord] = [], second: [EventStreamRecord] = []
        var firstSuppressed: [Int] = [], secondSuppressed: [Int] = []
        let a = try shared.subscribe(shouldCapture: { $0 == "first" }, onRecord: { first.append($0) }, onSuppressedRecord: { firstSuppressed.append($0.id) })
        check("first subscription starts shared recorder once", recorder.startCount == 1 && recorder.isRecording && shared.subscriptionCount == 1)
        check("initial boundary and current window reach first consumer", first.map(\.kind) == [.sessionStarted,.windowChanged] && first.map(\.id) == [1,2])
        check("initial application policy accepts only requested app", recorder.shouldCaptureApplication?("first") == true && recorder.shouldCaptureApplication?("second") == false)
        let b = try shared.subscribe(shouldCapture: { $0 == "second" }, onRecord: { second.append($0) }, onSuppressedRecord: { secondSuppressed.append($0.id) })
        check("second subscription preserves shared recorder", recorder.startCount == 1 && shared.subscriptionCount == 2)
        check("second receives its own boundary plus refreshed window", second.map(\.kind) == [.sessionStarted,.windowChanged] && second.map(\.id) == [3,4])
        check("existing subscriber sees refresh but no duplicate start", first.map(\.kind) == [.sessionStarted,.windowChanged,.windowChanged])
        check("application policies use OR across all subscribers", recorder.shouldCaptureApplication?("first") == true && recorder.shouldCaptureApplication?("second") == true && recorder.shouldCaptureApplication?("other") == false)
        let click = EventStreamRecord(id: 99, timestamp: Date(timeIntervalSince1970: 1), kind: .mouseClick)
        recorder.onRecordStored?(click)
        check("records broadcast to both sinks without applying app gate again", first.last == click && second.last == click)
        recorder.onSuppressedRecordStored?(click)
        check("suppressed records have a separate broadcast channel", firstSuppressed == [99] && secondSuppressed == [99])
        recorder.pending = [.init(id: 100, timestamp: click.timestamp, kind: .keyboardTextInput)]
        let firstBefore = first.count, secondBefore = second.count
        shared.unsubscribe(a)
        check("unsubscribe flushes pending records before its end boundary", first.dropFirst(firstBefore).map(\.kind) == [.keyboardTextInput,.sessionEnded])
        check("remaining sink sees pending record and window refresh without another end", second.dropFirst(secondBefore).map(\.kind) == [.keyboardTextInput,.windowChanged])
        check("removing one subscriber leaves producer and callbacks alive", recorder.isRecording && recorder.stopFlags.isEmpty && recorder.hasCallbacks && shared.subscriptionCount == 1)
        check("application policy drops removed subscriber", recorder.shouldCaptureApplication?("first") == false && recorder.shouldCaptureApplication?("second") == true)
        let flushBefore = recorder.flushCount
        shared.unsubscribe(a)
        check("duplicate unsubscribe is a complete no-op", recorder.flushCount == flushBefore && shared.subscriptionCount == 1)
        shared.unsubscribe(b)
        check("last unsubscribe emits exactly one end boundary", second.filter { $0.kind == .sessionEnded }.count == 1)
        check("last unsubscribe stops without duplicate producer boundary", recorder.stopFlags == [false] && !recorder.isRecording)
        check("last unsubscribe detaches all three callbacks", !recorder.hasCallbacks && shared.subscriptionCount == 0)
        shared.unsubscribe(b)
        check("duplicate final unsubscribe does not stop twice", recorder.stopFlags == [false])
        var fresh: [EventStreamRecord] = []
        let c = try shared.subscribe(shouldCapture: { _ in false }, onRecord: { fresh.append($0) })
        check("subscribing after complete stop starts a new producer session", recorder.startCount == 2 && fresh.first?.id == 1 && recorder.isRecording)
        check("optional suppressed handler needs no fabricated callback", firstSuppressed == [99] && secondSuppressed == [99])
        shared.unsubscribe(c)

        let failing = Recorder()
        failing.failStart = true
        let failureCoordinator = EventStreamCaptureCoordinator(recorder: failing)
        var observedError = false
        do { _ = try failureCoordinator.subscribe(shouldCapture: { _ in true }, onRecord: { _ in }); }
        catch Recorder.Failure.start { observedError = true }
        check("producer startup error propagates", observedError)
        check("failed first subscription removes its sink and hooks", failureCoordinator.subscriptionCount == 0 && !failing.hasCallbacks)
        failing.failStart = false
        let recovered = try failureCoordinator.subscribe(shouldCapture: { _ in true }, onRecord: { _ in })
        check("startup failure does not poison next subscription", failureCoordinator.subscriptionCount == 1 && failing.isRecording && failing.startCount == 2)
        failureCoordinator.unsubscribe(recovered)

        let recursive = Recorder()
        let rc = EventStreamCaptureCoordinator(recorder: recursive)
        var recursiveToken: EventStreamCaptureSubscription?
        var recursiveEvents: [EventStreamEventKind] = []
        recursiveToken = try rc.subscribe(shouldCapture: { _ in true }, onRecord: {
            recursiveEvents.append($0.kind)
            if $0.kind == .sessionEnded, let token = recursiveToken { rc.unsubscribe(token) }
        })
        rc.unsubscribe(recursiveToken!)
        check("reentrant unsubscribe during boundary cannot recurse or double-stop", recursive.stopFlags == [false] && recursiveEvents.filter { $0 == .sessionEnded }.count == 1 && rc.subscriptionCount == 0)

        let mutation = Recorder()
        let mutatingCoordinator = EventStreamCaptureCoordinator(recorder: mutation)
        var late: EventStreamCaptureSubscription?, oldEvents: [EventStreamEventKind] = [], lateEvents: [EventStreamEventKind] = []
        let old = try mutatingCoordinator.subscribe(shouldCapture: { _ in true }, onRecord: { oldEvents.append($0.kind) })
        mutation.onFlush = {
            late = try! mutatingCoordinator.subscribe(shouldCapture: { _ in true }, onRecord: { lateEvents.append($0.kind) })
        }
        mutatingCoordinator.unsubscribe(old)
        check("subscription added during flush keeps producer running", mutation.isRecording && mutation.stopFlags.isEmpty && mutatingCoordinator.subscriptionCount == 1)
        check("new sink does not receive departing sink's boundary", !lateEvents.contains(.sessionEnded) && oldEvents.filter { $0 == .sessionEnded }.count == 1)
        mutatingCoordinator.unsubscribe(late!)

        let broadcasting = Recorder()
        let bc = EventStreamCaptureCoordinator(recorder: broadcasting)
        var removedDuringBroadcast: EventStreamCaptureSubscription?, one: [Int] = [], two: [Int] = []
        let oneToken = try bc.subscribe(shouldCapture: { _ in true }, onRecord: {
            one.append($0.id)
            if $0.id == 99, let token = removedDuringBroadcast { bc.unsubscribe(token) }
        })
        removedDuringBroadcast = try bc.subscribe(shouldCapture: { _ in true }, onRecord: { two.append($0.id) })
        broadcasting.onRecordStored?(click)
        check("broadcast snapshot survives subscription removal from a callback", one.filter { $0 == 99 }.count == 1 && two.filter { $0 == 99 }.count == 1 && bc.subscriptionCount == 1)
        bc.unsubscribe(oneToken)

        weak var released: EventStreamCaptureCoordinator<Recorder>?
        let abandonedRecorder = Recorder()
        do {
            let temporary = EventStreamCaptureCoordinator(recorder: abandonedRecorder)
            released = temporary
            _ = try temporary.subscribe(shouldCapture: { _ in true }, onRecord: { _ in })
        }
        check("producer hooks do not retain coordinator", released == nil)
        check("orphan policy fails closed", abandonedRecorder.shouldCaptureApplication?("anything") == false)
        abandonedRecorder.onRecordStored?(click)
        abandonedRecorder.onSuppressedRecordStored?(click)

        check("native event mask is the seven input event types", EventStreamInputPolicy.eventTypes.map(\.rawValue) == [1,2,3,4,25,26,10] && EventStreamInputPolicy.eventMask == 0x600041E)
        check("mask excludes movement, dragged, key-up and scroll", [CGEventType.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyUp,.scrollWheel].allSatisfy { EventStreamInputPolicy.eventMask & (1 << $0.rawValue) == 0 })
        check("modifier order is command/control/option/shift/function", EventStreamInputPolicy.modifiers([.maskCommand,.maskControl,.maskAlternate,.maskShift,.maskSecondaryFn,.maskAlphaShift,.maskNumericPad]) == ["command","control","option","shift","function"])
        check("irrelevant flags produce no modifiers", EventStreamInputPolicy.modifiers([.maskAlphaShift,.maskNumericPad]).isEmpty)
        check("both edges use canonical mouse button names", EventStreamInputPolicy.eventTypes.prefix(6).map(EventStreamInputPolicy.button) == ["left","left","right","right","other","other"])
        check("keyboard has no mouse button", EventStreamInputPolicy.button(.keyDown) == nil)
        let origin = CGPoint(x: 10, y: 20)
        check("drag threshold is exactly six points inclusive", !EventStreamInputPolicy.isDrag(button: "left", originButton: "left", origin: origin, destination: CGPoint(x:15.999,y:20)) && EventStreamInputPolicy.isDrag(button: "left", originButton: "left", origin: origin, destination: CGPoint(x:16,y:20)))
        check("drag uses Euclidean distance", EventStreamInputPolicy.isDrag(button: "left", originButton: "left", origin: origin, destination: CGPoint(x:14,y:25)))
        check("mismatched mouse buttons and unmatched release are not drags", !EventStreamInputPolicy.isDrag(button: "right", originButton: "left", origin: origin, destination: CGPoint(x:100,y:100)) && !EventStreamInputPolicy.isDrag(button: "left", originButton: "left", origin: nil, destination: CGPoint(x:100,y:100)))
        check("drag outranks context-menu classification", EventStreamInputPolicy.mouseKind(button: "right", flags: .maskControl, isDrag: true) == .mouseDrag)
        check("right and control clicks become context menus", EventStreamInputPolicy.mouseKind(button: "right", flags: [], isDrag: false) == .mouseContextMenu && EventStreamInputPolicy.mouseKind(button: "left", flags: .maskControl, isDrag: false) == .mouseContextMenu)
        check("ordinary left and other clicks retain click kind", EventStreamInputPolicy.mouseKind(button: "left", flags: .maskShift, isDrag: false) == .mouseClick && EventStreamInputPolicy.mouseKind(button: "other", flags: [], isDrag: false) == .mouseClick)
        check("Unicode and option text are text input", EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "ação 世界 🧪e\u{301}", flags: [.maskAlternate,.maskShift]))
        check("command and control exclude otherwise printable text", !EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "a", flags: .maskCommand) && !EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "a", flags: .maskControl))
        check("function and globe keys are excluded even with printable characters", !EventStreamInputPolicy.isTextInput(keyCode: 63, characters: "x", flags: []) && !EventStreamInputPolicy.isTextInput(keyCode: 179, characters: "x", flags: []))
        check("empty text and all C0 controls/DEL are excluded", !EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "", flags: []) && (Array(0...31)+[127]).allSatisfy { !EventStreamInputPolicy.isTextInput(keyCode: 0, characters: String(Unicode.Scalar($0)!), flags: []) })
        check("all AppKit function-key private scalars are excluded", (0xF700...0xF8FF).allSatisfy { !EventStreamInputPolicy.isTextInput(keyCode: 0, characters: String(Unicode.Scalar($0)!), flags: []) })
        check("private scalar interval boundaries are exact", EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "\u{F6FF}\u{F900}", flags: []))
        check("one invalid scalar rejects mixed text", !EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "valid\ntext", flags: []))
        check("C1 scalars are accepted as text input", EventStreamInputPolicy.isTextInput(keyCode: 0, characters: "\u{80}\u{9F}", flags: []))
        let names: [(UInt16,String)] = [(36,"return"),(76,"return"),(48,"tab"),(51,"delete"),(53,"escape"),(63,"function"),(117,"forward_delete"),(123,"left_arrow"),(124,"right_arrow"),(125,"down_arrow"),(126,"up_arrow"),(179,"globe")]
        check("all special key names match the expected names", names.allSatisfy { EventStreamInputPolicy.keyEquivalent(keyCode: $0.0, charactersIgnoringModifiers: "ignored") == $0.1 })
        check("unmapped key uses exact charactersIgnoringModifiers", EventStreamInputPolicy.keyEquivalent(keyCode: 0, charactersIgnoringModifiers: "Á") == "Á")
        var lookedUp: [UInt32] = []
        let owner: (UInt32) -> Int32? = { lookedUp.append($0); return $0 == 7 ? 321 : nil }
        check("window owner outranks event target PID", EventStreamInputPolicy.target(windowID: 7, targetPID: 123, windowOwner: owner) == .init(processIdentifier: 321, windowID: 7))
        check("missing window owner falls back to event target PID", EventStreamInputPolicy.target(windowID: 8, targetPID: 123, windowOwner: owner) == .init(processIdentifier: 123, windowID: 8))
        check("zero window is absent and not looked up", EventStreamInputPolicy.target(windowID: 0, targetPID: 123, windowOwner: owner) == .init(processIdentifier: 123, windowID: nil) && lookedUp == [7,8])
        check("invalid PID never truncates to another process", [Int64(0),-1,Int64(Int32.max)+1].allSatisfy { EventStreamInputPolicy.target(windowID: nil, targetPID: $0, windowOwner: owner).processIdentifier == nil })
        let mouse = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: 41,y: 93), mouseButton: .left)!
        mouse.setIntegerValueField(.eventTargetUnixProcessID, value: 123)
        mouse.setIntegerValueField(CGEventField(rawValue: 51)!, value: 7)
        mouse.setIntegerValueField(.mouseEventClickState, value: 2)
        mouse.flags = [.maskShift]
        let observation = EventStreamInputObservation.read(type: .leftMouseUp, event: mouse, windowOwner: owner)
        check("CGEvent decoding preserves click metadata and coordinates", observation?.type == .leftMouseUp && observation?.location == CGPoint(x:41,y:93) && observation?.clickCount == 2 && observation?.flags == .maskShift && observation?.target.processIdentifier == 321)
        check("mouse observation has no invented keyboard content", observation?.keyCode == nil && observation?.characters == "" && observation?.charactersIgnoringModifiers == "")
        let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let unicode = Array("é🧪".utf16)
        unicode.withUnsafeBufferPointer { keyboard.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
        keyboard.setIntegerValueField(.eventTargetUnixProcessID, value: 123)
        let keyObservation = EventStreamInputObservation.read(type: .keyDown, event: keyboard, windowOwner: owner)
        check("constructed CGEvent preserves Unicode keyboard content without posting input", keyObservation?.keyCode == 0 && keyObservation?.characters == "é🧪" && keyObservation?.target.processIdentifier == 123)
        check("unobserved event types are discarded", EventStreamInputObservation.read(type: .mouseMoved, event: mouse, windowOwner: owner) == nil)
        let tap = EventStreamInputTap()
        check("input tap has no automatic global startup", !tap.isInstalled)
        tap.stop(); tap.stop()
        check("stopping unstarted input source is idempotent", !tap.isInstalled)
        print("EVENT STREAM CAPTURE COORDINATION AND INPUT: \(checks) checks passed")
    }
}
