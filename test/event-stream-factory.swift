import Foundation

@main
struct EventStreamFactoryTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ label: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(label)") }
        checks += 1; print("PASS: \(label)")
    }
    @MainActor static func until(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { fatalError("Timed out awaiting capture") }
            await Task.yield()
        }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let identity = EventStreamRecordIdentity(id: 17, timestamp: Date(timeIntervalSince1970: 42))
        let oldApp = EventStreamApp(name: "Before", secureInput: false, processIdentifier: 10, bundleIdentifier: "fixture.before")
        let newApp = EventStreamApp(name: "After", secureInput: true, processIdentifier: 20, bundleIdentifier: "fixture.after")
        let oldWindow = EventStreamWindow(title: "Before", url: "https://before.test", windowID: 30)
        let newWindow = EventStreamWindow(title: "After", url: "https://after.test", windowID: 40)
        let target = EventStreamEventTarget(identity: .init(processIdentifier: 10, windowID: 30), app: oldApp, window: oldWindow)
        let tree = EventStreamAXTree(mode: .diffFromPrevious, text: "+ AXButton title=\"changed\"")
        func assemble(_ kind: EventStreamEventKind = .mouseClick, target: EventStreamEventTarget? = target,
                      app: EventStreamApp? = oldApp, window: EventStreamWindow? = oldWindow,
                      ax: EventStreamAXTree? = tree, suppress: Bool = true) -> EventStreamRecordDelivery {
            EventStreamRecordFactory.assemble(identity: identity, kind: kind, target: target,
                capture: .init(ax: ax, app: app, window: window), suppressWhenAXUnchanged: suppress)
        }
        let matched = assemble()
        check("matching capture retains exact input identity and timestamp", matched.record.id == 17 && matched.record.timestamp == identity.timestamp)
        check("useful captured diff is retained and not suppressed", matched.record.ax == tree && !matched.isSuppressed)
        for kind in [EventStreamEventKind.mouseClick, .mouseContextMenu, .mouseDrag, .keyboardTextInput, .keyboardSubmit, .keyboardShortcut] {
            let otherProcess = assemble(kind, app: newApp)
            check("\(kind.rawValue): PID change drops unrelated AX", otherProcess.record.ax == nil && otherProcess.isSuppressed)
            check("\(kind.rawValue): input retains original app after capture", otherProcess.record.app == oldApp)
            let otherWindow = assemble(kind, window: newWindow)
            check("\(kind.rawValue): window change drops AX and retains observed window", otherWindow.record.ax == nil && otherWindow.record.window == oldWindow)
        }
        for kind in [EventStreamEventKind.sessionStarted, .sessionEnded, .windowChanged, .terminalValueChanged, .selectionChanged, .debugError] {
            let result = assemble(kind, app: newApp, window: newWindow)
            check("\(kind.rawValue): fresh captured context is allowed", result.record.app == newApp && result.record.window == newWindow && result.record.ax == tree)
        }
        var metadataChanged = oldApp; metadataChanged.name = "renamed"; metadataChanged.secureInput = true
        check("input preserves observed app metadata even when PID is unchanged", assemble(app: metadataChanged).record.app == oldApp)
        var changedWindow = oldWindow; changedWindow.title = "renamed"; changedWindow.url = "https://updated.test"
        check("matching input accepts fresh title and URL", assemble(window: changedWindow).record.window == changedWindow)
        check("missing captured app/window fall back to original metadata", assemble(app: nil, window: nil).record.app == oldApp && assemble(app: nil, window: nil).record.window == oldWindow)
        let onlyWindow = EventStreamEventTarget(identity: .init(), window: oldWindow)
        check("window-only input does not borrow captured app", assemble(target: onlyWindow, app: newApp).record.app == nil)
        let onlyApp = EventStreamEventTarget(identity: .init(), app: oldApp)
        check("app-only input can use captured window", assemble(target: onlyApp, window: newWindow).record.window == newWindow)
        let bareIdentity = EventStreamEventTarget(identity: target.identity)
        let bareMismatch = assemble(target: bareIdentity, app: newApp, window: newWindow)
        check("identity without metadata still rejects mismatched tree/window", bareMismatch.record.ax == nil && bareMismatch.record.window == nil)
        check("identity without metadata can use fresh captured app", bareMismatch.record.app == newApp)
        check("absent target accepts current context", assemble(target: nil, app: newApp, window: newWindow).record.ax == tree)
        let unknown = EventStreamEventTarget(identity: .init())
        check("unknown identities do not establish a mismatch", assemble(target: unknown, app: newApp, window: newWindow).record.ax == tree)
        for pid in [Int32(0), -1, .min] {
            let invalid = EventStreamEventTarget(identity: .init(processIdentifier: pid), app: oldApp)
            check("nonpositive expected PID \(pid) does not establish mismatch", assemble(target: invalid, app: newApp).record.ax == tree)
            var invalidCaptured = newApp; invalidCaptured.processIdentifier = pid
            check("nonpositive captured PID \(pid) does not establish mismatch", assemble(app: invalidCaptured).record.ax == tree)
        }
        let zeroWindow = EventStreamEventTarget(identity: .init(windowID: 0), window: .init(windowID: 0))
        check("zero window ID is a present identity", assemble(target: zeroWindow, window: oldWindow).record.ax == nil)
        for text in ["There has been no change", "There has been no change\nin the selected window", "no_change"] {
            let payload = EventStreamAXTree(mode: .diffFromPrevious, text: text)
            let result = assemble(ax: payload)
            check("unchanged marker suppresses eligible record: \(text.debugDescription)", result.isSuppressed && result.record.ax == payload)
            check("unchanged marker still delivers ineligible record: \(text.debugDescription)", !assemble(ax: payload, suppress: false).isSuppressed)
        }
        for text in ["", "no_change\n", " no_change", "there has been no change", "There has been no chang"] {
            check("non-marker text remains useful: \(text.debugDescription)", !assemble(ax: .init(mode: .fullTree, text: text)).isSuppressed)
        }
        check("missing tree suppresses eligible record", assemble(ax: nil).isSuppressed)
        check("missing tree does not suppress interactive/drag record", !assemble(ax: nil, suppress: false).isSuppressed)
        check("mismatched tree cannot make eligible record useful", assemble(app: newApp).isSuppressed)
        check("mismatch does not suppress an ineligible record", !assemble(app: newApp, suppress: false).isSuppressed)

        var sequence = 100, captures: [(EventStreamEventTarget?, Bool)] = [], errors = 0
        var continuations: [CheckedContinuation<EventStreamAXCaptureResult, Error>] = []
        let factory = EventStreamRecordFactory(nextIdentity: { sequence += 1; return .init(id: sequence, timestamp: Date(timeIntervalSince1970: Double(sequence))) },
            capture: { target, preferDiff in
                captures.append((target, preferDiff))
                return try await withCheckedThrowingContinuation { continuations.append($0) }
            }, onCaptureError: { _ in errors += 1 })
        let key = EventStreamKeyboardInteraction(keyEquivalent: "ArrowLeft", modifiers: ["shift"], target: .init(role: "AXTextField", value: "value"))
        let noAX = await factory.make(.init(identity: identity, kind: .keyboardShortcut, target: target,
            mouse: nil, keyboard: key, capturesAX: false, suppressWhenAXUnchanged: true))
        check("noncapturing shortcut never queries capture backend", captures.isEmpty)
        check("noncapturing shortcut retains payload/context and bypasses suppression", noAX.record.keyboard == key && noAX.record.app == oldApp && noAX.record.window == oldWindow && noAX.record.ax == nil && !noAX.isSuppressed)
        check("provided shortcut identity does not allocate sequence", sequence == 100 && noAX.record.id == 17)
        let pending = Task { await factory.make(identity: identity, kind: .mouseClick, target: target, suppressWhenAXUnchanged: true) }
        await until { continuations.count == 1 }
        check("capture receives original target and default diff preference", captures[0].0?.identity == target.identity && captures[0].1)
        continuations.removeFirst().resume(returning: .init(ax: tree, app: newApp, window: newWindow))
        let moved = await pending.value
        check("focus change during await cannot attach foreign tree", moved.record.ax == nil && moved.record.app == oldApp && moved.record.window == oldWindow && moved.isSuppressed)
        check("provided capture identity survives await", sequence == 100 && moved.record.id == 17 && moved.record.timestamp == identity.timestamp)
        let generated = Task { await factory.make(kind: .selectionChanged, target: nil, preferDiff: false) }
        await until { continuations.count == 1 }
        check("missing identity not allocated before capture completes", sequence == 100)
        check("explicit full-tree preference reaches capture backend", captures.last?.1 == false && captures.last?.0 == nil)
        continuations.removeFirst().resume(returning: .init(ax: tree, app: newApp, window: newWindow))
        let generatedRecord = await generated.value
        check("missing identity allocated at completion", generatedRecord.record.id == 101 && generatedRecord.record.timestamp == Date(timeIntervalSince1970: 101))
        enum Failure: Error { case unavailable }
        let failed = Task { await factory.make(kind: .mouseClick, target: target, suppressWhenAXUnchanged: true) }
        await until { continuations.count == 1 }
        continuations.removeFirst().resume(throwing: Failure.unavailable)
        let fallback = await failed.value
        check("capture failure reports error once", errors == 1)
        check("capture failure retains original context without AX or diagnostic", fallback.record.app == oldApp && fallback.record.window == oldWindow && fallback.record.ax == nil && fallback.record.diagnostic == nil && fallback.isSuppressed)
        check("capture failure still allocates missing identity", fallback.record.id == 102)
        let cancelled = Task { await factory.make(kind: .selectionChanged) }
        await until { continuations.count == 1 }
        cancelled.cancel(); continuations.removeFirst().resume(throwing: CancellationError())
        let cancelledOutput = await cancelled.value
        check("capture cancellation recovers without fabricating context", errors == 2 && cancelledOutput.record.app == nil && cancelledOutput.record.window == nil && cancelledOutput.record.ax == nil && !cancelledOutput.isSuppressed)
        let mouse = EventStreamMouseInteraction(button: "right", clickCount: 2, modifiers: ["control"])
        let payload = EventStreamRecordFactory.assemble(identity: identity, kind: .selectionChanged, target: nil,
            mouse: mouse, keyboard: key, capture: .init(ax: tree, app: newApp, window: newWindow), suppressWhenAXUnchanged: false)
        check("input factory preserves mouse/keyboard and leaves selection to its separate path", payload.record.mouse == mouse && payload.record.keyboard == key && payload.record.selection == nil)
        let encoded = try JSONEncoder().encode(payload.record)
        let decoded = try JSONDecoder().decode(EventStreamRecord.self, from: encoded)
        check("assembled record round-trips through its Codable contract", decoded == payload.record)

        var reads: [(UInt32, Int?)] = [], renderModes: [EventStreamAXTree.Mode] = []
        var renderOptions: [(Bool, Bool)] = [], revision = 0, failContext = false, failCapture = false
        let axCapture = EventStreamAXCapture<UInt32, Int>(resolveContext: { target in
            if failContext { throw Failure.unavailable }
            return target?.identity.windowID ?? 30
        }, contextWindowID: { $0 }, captureTree: { window, previous in
            reads.append((window, previous))
            if failCapture { throw Failure.unavailable }
            revision += 1
            return .init(revision: revision, windowID: window, app: oldApp,
                         window: .init(title: "capture \(revision)", windowID: window))
        }, render: { snapshot, mode, withoutRemovalSubtree, ignoreDifferenceBudget in
            renderModes.append(mode); renderOptions.append((withoutRemovalSubtree, ignoreDifferenceBudget))
            return mode == .diffFromPrevious ? "no_change" : "tree \(snapshot.revision)"
        })
        let first = try await axCapture.capture(target, preferDiff: true)
        check("first capture has no revision and uses fullTree", reads.last?.1 == nil && first.ax?.mode == .fullTree && first.ax?.text == "tree 1")
        let second = try await axCapture.capture(target, preferDiff: true)
        check("same window continues prior revision and uses diff", reads.last?.1 == 1 && second.ax?.mode == .diffFromPrevious && second.ax?.text == "no_change")
        check("renderer receives removal-subtree and budget options", renderOptions.allSatisfy { $0.0 && $0.1 })
        let full = try await axCapture.capture(target, preferDiff: false)
        check("explicit full capture omits previous revision", reads.last?.1 == nil && full.ax?.mode == .fullTree)
        _ = try await axCapture.capture(target, preferDiff: true)
        check("full capture still replaces next diff baseline", reads.last?.1 == 3)
        let otherTarget = EventStreamEventTarget(identity: .init(windowID: 40))
        _ = try await axCapture.capture(otherTarget, preferDiff: true)
        check("different window starts full capture", reads.last?.1 == nil && renderModes.last == .fullTree && axCapture.previousWindowID == 40)
        _ = try await axCapture.capture(target, preferDiff: true)
        check("return to older window does not borrow a per-window revision", reads.last?.1 == nil && renderModes.last == .fullTree)
        failCapture = true
        do { _ = try await axCapture.capture(otherTarget, preferDiff: true); fatalError("expected capture error") } catch Failure.unavailable {}
        check("failed capture preserves previous window baseline", axCapture.previousWindowID == 30)
        failCapture = false
        _ = try await axCapture.capture(target, preferDiff: true)
        check("failed capture does not replace prior successful revision", reads.last?.1 == 6)
        failContext = true; let readCount = reads.count
        do { _ = try await axCapture.capture(target, preferDiff: true); fatalError("expected context error") } catch Failure.unavailable {}
        check("context error skips tree and preserves baseline", reads.count == readCount && axCapture.previousWindowID == 30)
        failContext = false; axCapture.reset()
        check("owner reset clears cached window identity", axCapture.previousWindowID == nil)
        _ = try await axCapture.capture(target, preferDiff: true)
        check("owner reset clears cached revision", reads.last?.1 == nil && renderModes.last == .fullTree)

        var deferred: [UInt32: CheckedContinuation<EventStreamAXTreeCapture<Int>, Error>] = [:]
        let racingCapture = EventStreamAXCapture<UInt32, Int>(resolveContext: { $0?.identity.windowID ?? 30 },
            contextWindowID: { $0 }, captureTree: { window, _ in
                try await withCheckedThrowingContinuation { deferred[window] = $0 }
            }, render: { _, _, _, _ in "tree" })
        let captureA = Task { try await racingCapture.capture(target, preferDiff: true) }
        let captureB = Task { try await racingCapture.capture(otherTarget, preferDiff: true) }
        await until { deferred.count == 2 }
        deferred.removeValue(forKey: 40)!.resume(returning: .init(revision: 40, windowID: 40, app: newApp, window: newWindow))
        let resultB = try await captureB.value
        check("concurrent capture B retains its own metadata", resultB.window == newWindow && racingCapture.previousWindowID == 40)
        deferred.removeValue(forKey: 30)!.resume(returning: .init(revision: 30, windowID: 30, app: oldApp, window: oldWindow))
        let resultA = try await captureA.value
        check("late capture A retains its own metadata and becomes latest completed baseline", resultA.window == oldWindow && racingCapture.previousWindowID == 30)

        // Exercise the actual builder -> factory -> policy -> JSONL path with
        // controlled capture/URL providers, without enabling global recording.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-factory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try EventStreamJSONLWriter(sessionID: "fixture", rootDirectoryURL: directory)
        defer { writer.close() }
        var blocked = false, pipelineID = 200, policyCalls = 0
        var differenceLines: [String]? = []
        let renderTree = [EventStreamRenderNode(id:nil,description:"window",detail:nil,children:[
            .init(id:7,description:EventStreamPresentation(title:"Salvar",help:"á😀").accessibilityDescription(
                role:.init(nativeRole:"AXButton",roleDescription:"button"),state:.init(),contextKind:0,hasDescriptiveAttributes:true),detail:nil)
        ])]
        let filter = EventStreamURLPolicyRecordFilter(isURLBlocked: { _ in policyCalls += 1; return blocked },
            isWebBrowser: { _ in true }, resolveApplication: { app in
                .init(id: app.bundleIdentifier ?? "fixture", name: app.name ?? "fixture", bundleIdentifier: app.bundleIdentifier, bundleURL: nil, executableURL: nil)
            })
        let processor = EventStreamRecordProcessor(writer: writer, filter: filter, resolveApplication: { _ in nil })
        var pipelineCaptures = 0
        let pipelineFactory = EventStreamRecordFactory(nextIdentity: { fatalError("input identity must be retained") },
            capture: { _, _ in
                pipelineCaptures += 1
                return .init(ax: .init(mode: .diffFromPrevious,
                    text: EventStreamTreeRendering.description(renderTree,differenceLines:differenceLines,options:.withoutRemovalSubtree)), app: oldApp, window: oldWindow)
            })
        var pendingDeliveries: [Task<Void, Never>] = []
        let builder = EventStreamInputRecordBuilder<Int>(nextIdentity: { pipelineID += 1; return .init(id: pipelineID, timestamp: identity.timestamp) },
            isRecording: { true }, fallbackProcessIdentifier: { nil }, capturePermitted: { _ in true },
            keyboardTarget: { $0 }, resolveTarget: { _ in target }, endpointAt: { _, _ in nil },
            focusedTarget: { _ in .init() }, refreshTarget: { _ in .init() }, currentRole: { _ in nil }, characterCount: { _ in nil },
            resolveTextContext: { _ in (oldApp, oldWindow) }, sleep: { _ in },
            emitText: { processor.receive($0) }, prepare: { interaction in
                pendingDeliveries.append(Task {
                    let delivery = await pipelineFactory.make(interaction)
                    processor.receive(delivery.record, isSuppressed: delivery.isSuppressed)
                })
            })
        func sendClick() {
            builder.receive(.init(type: .leftMouseUp, location: .zero, flags: [],
                target: .init(processIdentifier: 10, windowID: 30), clickCount: 1,
                keyCode: nil, characters: "", charactersIgnoringModifiers: ""))
        }
        func drain(_ expectedID: Int) async {
            await until { pipelineID == expectedID && builder.pendingInteractionCount == 0 && !pendingDeliveries.isEmpty }
            let tasks = pendingDeliveries; pendingDeliveries.removeAll()
            for task in tasks { await task.value }
            if let processing = processor.processingTask { await processing.value }
        }
        sendClick(); await drain(201)
        let firstBytes = try Data(contentsOf: writer.eventsURL)
        check("unchanged eligible input reaches policy but creates no JSONL record", firstBytes.isEmpty && policyCalls == 1 && pipelineCaptures == 1)
        differenceLines = nil; sendClick(); await drain(202)
        let jsonLines = try String(contentsOf: writer.eventsURL, encoding: .utf8).split(separator: "\n")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let committed = try decoder.decode(EventStreamRecord.self, from: Data(jsonLines[0].utf8))
        check("useful input commits rendered full fallback into real JSONL with original input identity", jsonLines.count == 1 && committed.id == 202 && committed.ax?.text == "window\n\t7 button Salvar, Help: á😀" && committed.app == oldApp)
        check("full render fallback preserves factory diff mode", committed.ax?.mode == .diffFromPrevious)
        blocked = true; sendClick(); await drain(203)
        let blockedBytes = try Data(contentsOf: writer.eventsURL)
        check("blocked URL input updates policy context without committing", processor.blockedCaptureContext?.normalizedURL.absoluteString == "https://before.test" && blockedBytes == Data((String(jsonLines[0]) + "\n").utf8))
        blocked = false; differenceLines = []; sendClick(); await drain(204)
        check("suppressed allowed input clears prior blocked policy context", processor.blockedCaptureContext == nil && policyCalls == 4)
        check("suppressed-events path remains absent after full pipeline", writer.suppressedEventsURL == nil && !FileManager.default.fileExists(atPath: writer.directoryURL.appendingPathComponent("suppressed.jsonl").path))
        print("EVENT STREAM RECORD FACTORY: \(checks) checks passed")
    }
}
