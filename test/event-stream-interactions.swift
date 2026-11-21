import Foundation
import CoreGraphics

@MainActor
private final class ClockGate {
    var durations: [Duration] = []
    var pending: [CheckedContinuation<Void, Error>] = []
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func releaseAll(error: Error? = nil) {
        let batch = pending; pending.removeAll()
        for continuation in batch {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}

@main
struct EventStreamInteractionTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ label: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(label)") }
        checks += 1; print("PASS: \(label)")
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Timed out") }
            await Task.yield()
        }
    }
    @MainActor static func settle() async { for _ in 0..<80 { await Task.yield() } }
    static func endpoint(_ role: String, pid: Int32? = 10, window: UInt32? = 20, title: String = "target") -> EventStreamMouseInteractionDragEndpoint {
        .init(app: .init(name: "Fixture", secureInput: false, processIdentifier: pid),
              window: .init(windowID: window), element: .init(role: role, title: title))
    }
    static func observation(_ type: CGEventType, x: Double = 0, clicks: Int64 = 1,
                            flags: CGEventFlags = [], code: UInt16? = nil,
                            text: String = "", pid: Int32? = 10, window: UInt32? = 20) -> EventStreamInputObservation {
        .init(type: type, location: .init(x: x, y: 0), flags: flags,
              target: .init(processIdentifier: pid, windowID: window), clickCount: clicks,
              keyCode: code, characters: text, charactersIgnoringModifiers: text)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        typealias Policy = EventStreamInteractionPolicy
        typealias Builder = EventStreamInputRecordBuilder<Int>
        let a = endpoint("AXButton"), b = endpoint("AXButton", title: "other")
        func mouse(_ origin: EventStreamMouseInteractionDragEndpoint?, _ destination: EventStreamMouseInteractionDragEndpoint?) -> EventStreamMouseInteraction {
            .init(button: "left", clickCount: 1, modifiers: [], target: origin?.element, origin: origin, destination: destination)
        }
        check("drag without either endpoint is omitted", Policy.omitMouse(kind: .mouseDrag, mouse: mouse(nil, nil)))
        check("drag with one known endpoint remains", !Policy.omitMouse(kind: .mouseDrag, mouse: mouse(a, nil)))
        check("equal complete drag endpoints are omitted", Policy.omitMouse(kind: .mouseDrag, mouse: mouse(a, a)))
        check("different interactive endpoints remain", !Policy.omitMouse(kind: .mouseDrag, mouse: mouse(a, b)))
        let textStart = endpoint("AXTextField"), textEnd = endpoint("AXStaticText", title: "selection")
        check("text selection across distinct elements of same app/window is omitted", Policy.omitMouse(kind: .mouseDrag, mouse: mouse(textStart, textEnd)))
        check("text drag to different app remains", !Policy.omitMouse(kind: .mouseDrag, mouse: mouse(textStart, endpoint("AXTextField", pid: 11))))
        check("text drag to different window remains", !Policy.omitMouse(kind: .mouseDrag, mouse: mouse(textStart, endpoint("AXTextField", window: 21))))
        check("missing PID does not prove text selection stays in one app", !Policy.omitMouse(kind: .mouseDrag, mouse: mouse(endpoint("AXTextArea", pid: nil), textEnd)))
        check("missing window does not prove text selection stays in one window", !Policy.omitMouse(kind: .mouseDrag, mouse: mouse(endpoint("AXTextArea", window: nil), textEnd)))
        for role in ["AXStaticText", "AXTextArea", "AXTextField"] {
            let click = EventStreamMouseInteraction(button: "left", clickCount: 2, modifiers: [], target: .init(role: role))
            check("multi-click text selection omitted for \(role)", Policy.omitMouse(kind: .mouseClick, mouse: click))
            check("context menu on text remains for \(role)", !Policy.omitMouse(kind: .mouseContextMenu, mouse: click))
        }
        check("all sixteen interactive roles are ineligible for unchanged-AX suppression", Policy.interactiveRoles.count == 16 && Policy.interactiveRoles.allSatisfy {
            !Policy.suppressMouseWhenAXUnchanged(kind: .mouseClick, mouse: .init(button: "left", clickCount: 1, modifiers: [], target: .init(role: $0)))
        })
        check("single click on unknown role is suppression eligible", Policy.suppressMouseWhenAXUnchanged(kind: .mouseClick, mouse: .init(modifiers: [])))
        check("drag is never suppression eligible", !Policy.suppressMouseWhenAXUnchanged(kind: .mouseDrag, mouse: .init(modifiers: [])))
        check("multi-click is never suppression eligible", !Policy.suppressMouseWhenAXUnchanged(kind: .mouseClick, mouse: .init(clickCount: 2, modifiers: [])))
        func key(_ code: UInt16, _ role: String?, flags: CGEventFlags = [], fresh: String? = nil, count: Int? = nil, bundle: String? = nil) -> Policy.KeyboardDecision {
            Policy.keyboard(keyCode: code, flags: flags, capturedRole: role, currentRole: fresh,
                            currentCharacterCount: count, bundleIdentifier: bundle)
        }
        check("Return outside text area is submit with AX", key(36, "AXTextField") == .init(kind: .keyboardSubmit, capturesAX: true))
        check("keypad Return outside text area is submit", key(76, nil).kind == .keyboardSubmit)
        check("Return in emptied text area is submit", key(36, "AXTextArea", fresh: "AXTextArea", count: 0).kind == .keyboardSubmit)
        check("Return in populated text area is shortcut without AX", key(36, "AXTextArea", fresh: "AXTextArea", count: 5) == .init(kind: .keyboardShortcut, capturesAX: false))
        check("unavailable character count does not invent submit", key(36, "AXTextArea", fresh: "AXTextArea").kind == .keyboardShortcut)
        check("changed current role does not invent submit", key(36, "AXTextArea", fresh: "AXTextField", count: 0).kind == .keyboardShortcut)
        check("Slack one-character text area is submit", key(36, "AXTextArea", fresh: "AXTextArea", count: 1, bundle: "com.tinyspeck.slackmacgap").kind == .keyboardSubmit)
        check("one character in other app is not submit", key(36, "AXTextArea", fresh: "AXTextArea", count: 1, bundle: "other").kind == .keyboardShortcut)
        check("Shift Return does not submit emptied text area", key(36, "AXTextArea", flags: .maskShift, fresh: "AXTextArea", count: 0).kind == .keyboardShortcut)
        check("Control and Option block text-area submit", [CGEventFlags.maskControl, .maskAlternate].allSatisfy { key(36, "AXTextArea", flags: $0, fresh: "AXTextArea", count: 0).kind == .keyboardShortcut })
        check("command shortcut captures AX even in text area", key(8, "AXTextArea", flags: .maskCommand) == .init(kind: .keyboardShortcut, capturesAX: true))
        check("arrows retain shortcut record without AX", key(123, "AXTextField") == .init(kind: .keyboardShortcut, capturesAX: false))
        check("Tab in text field skips AX, Tab outside captures AX", !key(48, "AXTextField").capturesAX && key(48, "AXButton").capturesAX)
        check("Delete and forward delete outside text roles capture AX", key(51, nil).capturesAX && key(117, nil).capturesAX)
        check("Escape and Globe capture AX in text area", key(53, "AXTextArea").capturesAX && key(179, "AXTextArea").capturesAX)
        check("function-only key remains shortcut without AX", key(63, nil, flags: .maskSecondaryFn) == .init(kind: .keyboardShortcut, capturesAX: false))

        let clock = ClockGate()
        var nextID = 0, resolves = 0, captures = 0, refreshes = 0, countReads = 0
        var active = true, permitted = true, permissionPIDs: [Int32?] = []
        var prepared: [EventStreamPreparedInteraction] = [], texts: [EventStreamRecord] = []
        var order: [String] = [], hits: [EventStreamEventTarget] = []
        var firstEndpoint: EventStreamMouseInteractionDragEndpoint? = a
        var lastEndpoint: EventStreamMouseInteractionDragEndpoint? = b
        var role = "AXTextField", freshRole = "AXTextField", chars: Int? = 0
        var contextBundle: String? = "fixture"
        let builder = Builder(nextIdentity: { nextID += 1; return .init(id: nextID, timestamp: Date(timeIntervalSince1970: Double(nextID))) },
            isRecording: { active }, fallbackProcessIdentifier: { 41 },
            capturePermitted: { permissionPIDs.append($0); return permitted },
            keyboardTarget: { _ in .init(processIdentifier: 17, windowID: 18) },
            resolveTarget: { identity in resolves += 1; return .init(identity: identity, app: .init(name: "Fixture", secureInput: false, processIdentifier: identity.processIdentifier, bundleIdentifier: contextBundle), window: .init(windowID: identity.windowID)) },
            endpointAt: { target, point in hits.append(target); return point.x < 3 ? firstEndpoint : lastEndpoint },
            focusedTarget: { _ in captures += 1; return .init(description: .init(role: role, value: "cached"), element: 1) },
            refreshTarget: { _ in refreshes += 1; return .init(role: freshRole, value: "fresh") },
            currentRole: { _ in freshRole },
            characterCount: { _ in countReads += 1; return chars },
            resolveTextContext: { ($0?.app, $0?.window) }, sleep: clock.sleep,
            emitText: { texts.append($0); order.append("text") },
            prepare: { prepared.append($0); order.append("interaction") })
        builder.receive(observation(.keyDown, code: 0, text: "a"))
        builder.receive(observation(.keyDown, code: 11, text: "b"))
        await until { clock.pending.count == 2 }
        check("printable keys share one lazy context and focused target", resolves == 1 && captures == 1 && nextID == 2)
        builder.receive(observation(.leftMouseDown))
        check("mouse down flushes text before capturing pointer endpoint", texts.count == 1 && texts[0].keyboard?.text == "ab" && order == ["text"] && hits.count == 1)
        builder.receive(observation(.leftMouseUp, x: 3))
        await until { clock.durations.contains(.milliseconds(250)) }
        check("mouse up waits 250 ms without immediate emission", prepared.isEmpty && builder.pendingInteractionCount == 1)
        clock.releaseAll();await until { prepared.count == 1 }
        check("click uses mouse-up endpoint and original identity timestamp", prepared[0].kind == .mouseClick && prepared[0].mouse?.target == b.element && prepared[0].identity.id == 4 && prepared[0].identity.timestamp == Date(timeIntervalSince1970: 4))
        check("interactive click requests AX without unconditional suppression", prepared[0].capturesAX && !prepared[0].suppressWhenAXUnchanged)
        builder.receive(observation(.leftMouseDown))
        builder.receive(observation(.leftMouseUp, x: 6, flags: .maskControl))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == 2 }
        check("drag at exactly six points outranks Control context menu", prepared.last?.kind == .mouseDrag && prepared.last?.mouse?.origin == a && prepared.last?.mouse?.destination == b)
        check("drag destination uses unconstrained system-wide hit context", hits.last?.identity == .init() && hits.last?.app == nil && hits.last?.window == nil)
        check("drag target descriptor is original down endpoint", prepared.last?.mouse?.target == a.element)
        builder.receive(observation(.rightMouseUp, x: 3))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == 3 }
        check("unpaired right up still records context menu", prepared.last?.kind == .mouseContextMenu)
        firstEndpoint = textStart;lastEndpoint = textEnd
        let beforeOmission = nextID
        builder.receive(observation(.leftMouseDown));builder.receive(observation(.leftMouseUp, x: 6))
        check("text selection drag consumes no output identity or delayed work", nextID == beforeOmission && builder.pendingInteractionCount == 0)
        builder.receive(observation(.leftMouseUp, x: 3, clicks: 2))
        check("left text multi-click is omitted before allocation", nextID == beforeOmission)
        firstEndpoint = a;lastEndpoint = b

        let beforeKey = prepared.count
        builder.receive(observation(.keyDown, code: 123))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == beforeKey + 1 }
        check("uncaptured arrow retains cached descriptor", prepared.last?.capturesAX == false && prepared.last?.keyboard?.target?.value == "cached")
        check("explicit event window survives a conflicting fallback provider", prepared.last?.target.identity == .init(processIdentifier: 10, windowID: 20))
        let beforeRefresh = refreshes
        builder.receive(observation(.keyDown, flags: .maskCommand, code: 8, text: "c"))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == beforeKey + 2 }
        check("command shortcut refreshes descriptor after delay", prepared.last?.capturesAX == true && prepared.last?.keyboard?.target?.value == "fresh" && refreshes == beforeRefresh + 1)
        role = "AXTextArea";freshRole = "AXTextArea";chars = 1;contextBundle = "com.tinyspeck.slackmacgap"
        builder.receive(observation(.keyDown, code: 36))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == beforeKey + 3 }
        check("delayed text-area Return queries current character count and Slack identity", prepared.last?.kind == .keyboardSubmit && countReads == 1)
        let beforeModifiedReturn = prepared.count
        builder.receive(observation(.keyDown, flags: .maskShift, code: 36))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == beforeModifiedReturn + 1 }
        check("modified Return skips character-count query and full AX refresh", countReads == 1 && prepared.last?.kind == .keyboardShortcut && prepared.last?.capturesAX == false)
        let beforeChangedRole = prepared.count
        freshRole = "AXTextField"
        builder.receive(observation(.keyDown, code: 36))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == beforeChangedRole + 1 }
        check("changed role skips stale character count", countReads == 1 && prepared.last?.kind == .keyboardShortcut && prepared.last?.capturesAX == false)
        freshRole = "AXTextArea"
        let beforeFallback = prepared.count
        builder.receive(observation(.keyDown, code: 123, pid: nil, window: nil))
        await until { !clock.pending.isEmpty };clock.releaseAll();await until { prepared.count == beforeFallback + 1 }
        check("capture policy uses fallback PID before keyboard-window fallback", permissionPIDs.last! == 41 && prepared.last?.target.identity == .init(processIdentifier: 17, windowID: 18))

        let beforeStop = prepared.count
        builder.receive(observation(.leftMouseUp, x: 3))
        await until { !clock.pending.isEmpty }
        builder.discardPendingInput()
        builder.receive(observation(.rightMouseUp, x: 3))
        await until { clock.pending.count >= 2 }
        clock.releaseAll();await until { prepared.count == beforeStop + 1 }
        check("old timer cannot emit across reset or remove new work", prepared.last?.kind == .mouseContextMenu && builder.pendingInteractionCount == 0)
        builder.receive(observation(.rightMouseUp, x: 3))
        await until { !clock.pending.isEmpty };active = false;clock.releaseAll();await settle()
        check("recording state is rechecked after interaction delay", prepared.count == beforeStop + 1 && builder.pendingInteractionCount == 0)
        let priorID = nextID;builder.receive(observation(.leftMouseDown))
        check("inactive builder ignores input before context lookup", nextID == priorID)
        active = true;permitted = false
        let priorResolves = resolves
        builder.receive(observation(.keyDown, code: 0, text: "blocked"))
        check("rejected application input has no identity, context or target side effects", nextID == priorID && resolves == priorResolves)
        permitted = true
        builder.receive(observation(.keyDown, code: 53))
        await until { !clock.pending.isEmpty };clock.releaseAll(error: CocoaError(.userCancelled));await settle()
        check("noncancellation sleep error still delivers interaction and releases task", prepared.count == beforeStop + 2 && prepared.last?.kind == .keyboardShortcut && builder.pendingInteractionCount == 0)
        builder.discardPendingInput()

        // Decoder -> builder uses a real CGEvent object, without posting input.
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        // A nil source copies the session's live modifier state; a modifier held by
        // another process would turn this text key into a shortcut.
        event.flags = []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 10)
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: 20)
        let unicode = Array("é👩🏽‍💻".utf16)
        event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        let read = EventStreamInputObservation.read(type: .keyDown, event: event, windowOwner: { _ in 10 })!
        builder.receive(read);builder.flushText()
        check("actual CGEvent decoder feeds exact Unicode into text recorder", texts.last?.keyboard?.text == "é👩🏽‍💻")
        await settle();clock.releaseAll();await settle()
        builder.discardPendingInput()
        print("EVENT STREAM INTERACTIONS: \(checks) checks passed")
    }
}
