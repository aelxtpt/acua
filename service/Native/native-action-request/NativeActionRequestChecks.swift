import AppKit
import Foundation

private enum ActionCheckFailure: Error { case action, stopped, admission, format }
private actor ActionCaptureGate {
    var entered = false
    private var release: CheckedContinuation<Void,Never>?
    func enter() async { entered = true;await withCheckedContinuation { release = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func finish() { release?.resume();release = nil }
}
@MainActor private final class ActionCoreFixture: ControllerActionRequestBackend {
    typealias Capture = String
    typealias Reply = String
    var trace: [String] = [], selected = 1, capture: String? = "captured"
    var failure: ActionCheckFailure?, block: URL?
    func requireNotStopped() throws { trace.append("stopped"); if failure == .stopped { throw ActionCheckFailure.stopped } }
    func admitAction() async throws { trace.append("admission"); if failure == .admission { throw ActionCheckFailure.admission } }
    func controllerForAction() -> Int { trace.append("controller"); return selected }
    func ensureFocus(_ controller: Int) { trace.append("focus\(controller)") }
    func setCursorActivity(_ value: UInt8, on controller: Int) { trace.append("activity\(value):\(controller)") }
    func dispatch(on controller: Int) async throws -> String? {
        trace.append("dispatch\(controller)"); if failure == .action { throw ActionCheckFailure.action }
        selected = 2; return capture
    }
    func blockedURL(_ capture: String) async -> URL? { trace.append("policy\(selected):\(capture)"); return block }
    func reply(_ capture: String?) throws -> String {
        trace.append("reply\(selected)"); if failure == .format { throw ActionCheckFailure.format }
        return capture ?? "no capture"
    }
}

@MainActor private final class DispatchFixture: ControllerActionDispatchBackend {
    typealias AppSnapshot = Int
    var coordinate: ControllerCoordinateClickParameters?, element: ControllerClickParameters?
    var value: ControllerSetValueParameters?, selection: ControllerTextSelectionParameters?
    var key: ControllerKeyboardActionParameters?, pasteValue: ControllerPasteParameters?
    var secondaryValue: (Int,String,Bool)?, scrollValue: (String,Double,Bool)?, calls = 0
    func done() -> Int? { calls += 1; return 41 }
    func coordinateClick(_ options: ControllerCoordinateClickParameters) async throws -> Int? { coordinate = options; return done() }
    func elementClick(_ options: ControllerClickParameters) async throws -> Int? { element = options; return done() }
    func secondary(elementID: Int, action: String, returnAppSnapshot: Bool) async throws -> Int? { secondaryValue = (elementID,action,returnAppSnapshot); return done() }
    func setValue(_ options: ControllerSetValueParameters) async throws -> Int? { value = options; return done() }
    func selectText(_ options: ControllerTextSelectionParameters) async throws -> Int? { selection = options; return done() }
    func scroll(at: XPCAppUsageBody.Target, direction: XPCAppUsageBody.ComputerUseIPCScrollDirection, pages: Double, returnAppSnapshot: Bool) async throws -> Int? { scrollValue = (direction.rawValue,pages,returnAppSnapshot); return done() }
    func keyboard(_ options: ControllerKeyboardActionParameters) async throws -> Int? { key = options; return done() }
    func paste(_ options: ControllerPasteParameters) async throws -> Int? { pasteValue = options; return done() }
}
@MainActor private final class PageFixture: ControllerPageScrollBackend {
    var trace: [String] = [], positions: [ControllerScaledCursorPosition] = [], deltas: [(Int,Int)] = []
    var visibleSize = CGSize(width: 600,height: 400), visibleOrigin = CGPoint(x: 10,y: 20), scalingFactor = 2.0
    var elementFrame: CGRect? = CGRect(x: 0,y: 0,width: 230,height: 45)
    var point: CGPoint? = CGPoint(x: 28,y: 38), settle = false, failMove = false
    func move(to position: ControllerScaledCursorPosition) async throws {
        trace.append("move");positions.append(position);if failMove { throw ActionCheckFailure.action }
        visibleSize = .init(width: 800,height: 500)
    }
    func prepare(_ id: Int) async throws -> Int { trace.append("prepare\(id)"); return id }
    func frame(_ element: Int) -> CGRect? { trace.append("frame");return elementFrame }
    func clickablePoint(_ element: Int) async throws -> CGPoint? {
        trace.append("point"); visibleSize = .init(width: 900,height: 700)
        visibleOrigin = .init(x: 5,y: 6);scalingFactor = 0; return point
    }
    func scroll(deltaX: Int,deltaY: Int) async throws { trace.append("scroll");deltas.append((deltaX,deltaY)) }
    func capture() async throws -> Int { trace.append("capture"); return 9 }
    func markNeedsSettle() { trace.append("mark");settle = true }
}

@MainActor enum NativeActionRequestChecks {
    static func run(output: URL) async throws -> Int32 {
        var rows: [[String:Any]] = []
        func check(_ name: String,_ passed: Bool) { rows.append(["name":name,"passed":passed]); if !passed { print("FAIL: "+name) } }
        do {
            let f = ActionCoreFixture(), reply = try await ControllerActionRequest(backend:f).perform()
            check("action completion uses captured controller while policy and reply reread current controller", reply == "captured" && f.trace == ["stopped","admission","controller","focus1","activity0:1","dispatch1","policy2:captured","activity1:1","reply2"])
        }
        do {
            let f = ActionCoreFixture();f.capture = nil
            let reply = try await ControllerActionRequest(backend:f).perform()
            check("absent action capture skips URL policy and still awaits finished cursor", reply == "no capture" && !f.trace.contains(where: { $0.hasPrefix("policy") }) && f.trace.suffix(2) == ["activity1:1","reply2"])
        }
        for error in [ActionCheckFailure.stopped,.admission,.action,.format] {
            let f = ActionCoreFixture();f.failure = error;var failed = false
            do { _ = try await ControllerActionRequest(backend:f).perform() } catch let got as ActionCheckFailure { failed = got == error }
            let expectedFinish = error == .format
            check("\(error) failure keeps request ordering and cursor cleanup boundary", failed && f.trace.contains("activity1:1") == expectedFinish && (error != .stopped || f.trace == ["stopped"]) && (error != .admission || f.trace == ["stopped","admission"]))
        }
        do {
            let f = ActionCoreFixture();f.block = URL(string:"https://EXAMPLE.invalid/p?q=1#f")!;var failed = false
            do { _ = try await ControllerActionRequest(backend:f).perform() }
            catch ControllerAppSnapshotRequestFailure.blockedURL(let url) { failed = url == f.block }
            check("blocked action URL preserves exact payload and leaves cursor acting without formatting", failed && f.trace.last == "policy2:captured" && !f.trace.contains("activity1:1"))
        }
        let f = DispatchFixture(), dispatch = ControllerActionDispatch(backend:f)
        _ = try await dispatch.perform(.click(at:.coordinate(.init(x:10.9,y:-3.9)),mouseButton:7,clickCount:0,duration:0,key:"Shift"),returnAppSnapshot:false)
        check("coordinate click retains raw button/count and truncates scaled coordinates toward zero", f.coordinate?.position == .init(x:10,y:-3) && f.coordinate?.button == 7 && f.coordinate?.count == 0 && f.coordinate?.hold == .zero && f.coordinate?.returnAppSnapshot == false && f.coordinate?.animateCursor == true)
        _ = try await dispatch.perform(.click(at:.elementID("+41"),mouseButton:2,clickCount:3,duration:nil,key:nil),returnAppSnapshot:true)
        check("element click uses numeric IDs, right only for button1 and disables animation", f.element?.elementID == 41 && f.element?.button == .left && f.element?.count == 3 && f.element?.animateCursor == false)
        _ = try await dispatch.perform(.performSecondaryAction(elementID:"-2",action:"AXShowMenu"),returnAppSnapshot:false)
        check("secondary action keeps signed ID and explicit capture selection", f.secondaryValue?.0 == -2 && f.secondaryValue?.1 == "AXShowMenu" && f.secondaryValue?.2 == false)
        for capture in [false,true] {
            _ = try await dispatch.perform(.setValue(elementID:"4",value:"ação 👋"),returnAppSnapshot:capture)
            check("setValue autosubmit follows sender capture selection \(capture)", f.value?.value == "ação 👋" && f.value?.autosubmitSearchFields == capture && f.value?.returnAppSnapshot == capture)
        }
        _ = try await dispatch.perform(.selectText(elementID:"4",text:"👋",prefix:"a",suffix:"b",selection:.cursorAfter),returnAppSnapshot:false)
        check("text selection forwards UTF text and cursor-after mode", f.selection?.text == "👋" && f.selection?.prefix == "a" && f.selection?.suffix == "b" && f.selection?.selection == .cursorAfter && f.selection?.returnAppSnapshot == false)
        _ = try await dispatch.perform(.scroll(at:.elementID("4"),direction:.left,pages:1.5),returnAppSnapshot:true)
        check("page scrolling keeps requested fractional pages and direction", f.scrollValue?.0 == "left" && f.scrollValue?.1 == 1.5 && f.scrollValue?.2 == true)
        _ = try await dispatch.perform(.drag(from:.init(x:5.9,y:6.9),to:.init(x:9.9,y:10.9)),returnAppSnapshot:false)
        check("drag reaches native coordinate path with scaled start and destination", f.coordinate?.position == .init(x:5,y:6) && f.coordinate?.destination == .init(x:9,y:10) && f.coordinate?.button == 0 && f.coordinate?.hold == nil)
        for seconds in [nil,0,30] as [Double?] {
            _ = try await dispatch.perform(.pressKey("Return",duration:seconds),returnAppSnapshot:true)
            check("press/hold distinguishes absent duration from zero and30 \(String(describing:seconds))", f.key?.kind == (seconds == nil ? .press:.hold) && f.key?.duration == seconds.map(Duration.seconds) && f.key?.waitForUIToSettle == true)
        }
        _ = try await dispatch.perform(.type("a👋"),returnAppSnapshot:false)
        check("type action keeps complete source and deferred capture selection", f.key?.kind == .type && f.key?.text == "a👋" && f.key?.returnAppSnapshot == false)
        for format in [XPCAppUsageBody.ComputerUseIPCPasteFormat.text,.md,.html] {
            _ = try await dispatch.perform(.paste(text:"owned",format:format),returnAppSnapshot:false)
            let expected: ControllerPasteFormat = format == .text ? .text : format == .md ? .markdown:.html
            check("paste wire format reaches native rich engine \(format.rawValue)", f.pasteValue?.format == expected && f.pasteValue?.returnAppSnapshot == false)
        }
        for bad in [-1.0,30.01,Double.infinity,Double.nan] {
            let previous = f.calls;var failed = false
            do { _ = try await dispatch.perform(.pressKey("a",duration:bad),returnAppSnapshot:true) }
            catch ControllerActionDispatchFailure.invalidDuration { failed = true }
            check("invalid key duration fails before native delivery \(bad)", failed && f.calls == previous)
        }
        for bad in [""," 4","4 ","x","9223372036854775808"] {
            let previous = f.calls;var failed = false
            do { _ = try await dispatch.perform(.setValue(elementID:bad,value:"x"),returnAppSnapshot:true) }
            catch ControllerActionDispatchFailure.invalidElementID { failed = true }
            check("invalid element identifier is rejected before mutation \(bad)", failed && f.calls == previous)
        }
        for direction in [XPCAppUsageBody.ComputerUseIPCScrollDirection.up,.down,.left,.right] {
            let p = PageFixture();_ = try await ControllerPageScroll(backend:p).perform(at:.coordinate(.init(x:4.9,y:5.9)),direction:direction,pages:0.5,returnAppSnapshot:true)
            let expected: (Int,Int) = direction == .up ? (0,250):direction == .down ? (0,-250):direction == .left ? (-400,0):(400,0)
            check("coordinate scroll reads extent after movement and preserves native direction \(direction.rawValue)", p.positions == [.init(x:4,y:5)] && p.deltas.count == 1 && p.deltas[0] == expected && p.trace == ["move","scroll","capture"] && !p.settle)
        }
        do {
            let p = PageFixture();_ = try await ControllerPageScroll(backend:p).perform(at:.elementID("+9"),direction:.down,pages:0.505,returnAppSnapshot:false)
            check("element scroll retains earlier frame, uses100pt floor and half-away rounding", p.deltas.count == 1 && p.deltas[0] == (0,-51) && p.trace == ["prepare9","frame","point","move","scroll","mark"])
            check("element scroll rereads geometry after clickable point and falls back from nonpositive scale", p.positions == [.init(x:23,y:32)] && p.settle)
        }
        do {
            let p = PageFixture();p.point = nil;p.elementFrame = nil
            _ = try await ControllerPageScroll(backend:p).perform(at:.elementID("9"),direction:.right,pages:1,returnAppSnapshot:true)
            check("missing element point skips movement and retains pre-await visible-size fallback", p.positions.isEmpty && p.deltas.count == 1 && p.deltas[0] == (600,0) && p.trace.last == "capture")
        }
        for pages in [0.0,-1,Double.nan] {
            let p = PageFixture();var failed = false
            do { _ = try await ControllerPageScroll(backend:p).perform(at:.coordinate(.zero),direction:.up,pages:pages,returnAppSnapshot:true) }
            catch ControllerActionDispatchFailure.invalidScrollPages { failed = true }
            check("invalid page count stops before movement \(pages)", failed && p.trace.isEmpty)
        }
        try await native(check:check)
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String:Any] = ["passed":passed,"checks":rows,"actual_mouse_keyboard_focus_capture_clipboard_or_cursor_window":false,
            "native_manager_queue_and_formatter_executed":true,"native_effect_providers_intercepted":true,
            "ordinary_request_routes_selected":false,"full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native action request: \(rows.filter { $0["passed"] as? Bool == true }.count)/\(rows.count)")
        return passed ? 0:3
    }
    private static func native(check: (String,Bool)->Void) async throws {
        let f = LifecycleFixture()
        var effects: [String] = [], controllers: [ControllerNativeAppController] = [], captureFlags: [Bool] = []
        var fail = false, captured = true, block: URL?, replacement: ControllerNativeAppController?
        let env = ControllerNativeActionRequestEnvironment(focus: { effects.append("focus");controllers.append($0) },
            activity: { controller,value in effects.append("activity\(value)");controllers.append(controller) },
            dispatch: { controller,_,flag in
                effects.append("dispatch");captureFlags.append(flag)
                if fail { throw ActionCheckFailure.action }
                if let replacement { f.bindings.manager.instance(for:f.target.identifier)!.controller = replacement }
                if !captured { return nil }
                return try NativeSecondaryScrollDataAppSnapshotBindingChecks.result(f.data)
            }, blockedURL: { controller,_ in effects.append("policy");controllers.append(controller);return block })
        var noInstance = false
        do { _ = try await f.lifecycle.performAction(f.target,requestedIdentifier:"owned alias",sender:nil,action:.type("owned"),requestEnvironment:env) }
        catch ControllerInstanceResolutionError.noInstance(let alias) { noInstance = alias == "owned alias" }
        check("native action requires an existing instance without launch or construction", noInstance && f.trace.values.isEmpty && effects.isEmpty)
        _ = try await f.lifecycle.start(f.target,requestedIdentifier:"owned alias",sender:nil)
        let instance = f.bindings.manager.instance(for:f.target.identifier)!, initialController = instance.controller
        let otherTarget = ComputerUseApplicationTarget(bundleIdentifier:"local.cua.replacement",url:URL(fileURLWithPath:"/private/tmp/Other %.app"))
        replacement = try f.make(otherTarget,instance.configuration)
        let reply = try await f.lifecycle.performAction(f.target,requestedIdentifier:"owned alias",sender:nil,action:.type("owned"),requestEnvironment:env)
        check("native action uses captured controller for both awaited activity changes", controllers.count == 4 && controllers[0] === initialController && controllers[1] === initialController && controllers[2] === replacement && controllers[3] === initialController)
        check("native action policy and reply reread current instance controller", reply.app.bundleIdentifier == otherTarget.bundleIdentifier && reply.app.appPath == otherTarget.url.path(percentEncoded:false) && reply.appSnapshot?.text == "owned capture result")
        check("native action preserves same canonical queue and does not call launch preparation again", f.trace.values.filter { $0 == "launch" }.count == 1 && f.bindings.manager.instance(for:f.target.identifier) === instance && effects == ["focus","activity0","dispatch","policy","activity1"])
        let decoded = try JSONDecoder().decode(ControllerIPCActionResult.self,from:JSONEncoder().encode(reply))
        let data = try JSONEncoder().encode(reply), normalized = try SocketResponseBody.normalizeData(data,for:"ComputerUseIPCAppPerformActionRequest") as! [String:Any]
        check("native action reply passes actual associated socket schema without instructions", normalized["appSpecificInstructions"] == nil && normalized["appSnapshot"] is [String:Any] && decoded == reply)
        replacement = nil;instance.controller = initialController
        for client in [nil,SenderClientMetadata.ClientType.nodeRepl,.unknown("node_repl"),.unknown("other")] {
            for runtime in [nil,SenderClientMetadata.MCPRuntime.legacyMCP,.nodeRepl] {
                var sender = SenderRequestContext(senderPID:getpid(),responsibleIdentity:nil,ancestorIdentities:[])
                sender.clientMetadata = .init(clientType:client,mcpRuntime:runtime);effects = [];captured = false
                let result = try await f.lifecycle.performAction(f.target,requestedIdentifier:"owned alias",sender:sender,action:.type("owned"),requestEnvironment:env)
                check("native action capture selection is independent of runtime client=\(String(describing:client)) runtime=\(String(describing:runtime))", captureFlags.last == (client != .nodeRepl) && result.appSnapshot == nil && effects == ["focus","activity0","dispatch","activity1"])
            }
        }
        for policy in [false,true] {
            effects = [];captured = true;fail = !policy
            block = policy ? URL(string:"https://blocked.invalid/p?q=1#f")!:nil
            var rejected = false
            do { _ = try await f.lifecycle.performAction(f.target,requestedIdentifier:"owned alias",sender:nil,action:.type("owned"),requestEnvironment:env) }
            catch ActionCheckFailure.action { rejected = !policy }
            catch ControllerAppSnapshotRequestFailure.blockedURL(let url) { rejected = policy && url == block }
            check("native \(policy ? "policy":"dispatch") failure skips finished cursor without replacing instance", rejected && !effects.contains("activity1") && instance.controller === initialController)
        }
        fail = false;block = nil
        do {
            let gate = ActionCaptureGate()
            var deactivated = false
            let blocked = ControllerNativeActionRequestEnvironment(focus:env.focus,activity:env.activity,
                dispatch: { _,_,_ in await gate.enter();return nil },blockedURL: { _,_ in nil })
            let first = Task { @MainActor in
                try await f.lifecycle.performAction(f.target,requestedIdentifier:"owned alias",sender:nil,
                    action:.type("owned"),requestEnvironment:blocked)
            }
            await gate.waitUntilEntered()
            let next = Task { @MainActor in
                let reply = try await f.lifecycle.modify(f.target,requestedIdentifier:"owned alias",sender:nil,deactivate:true)
                deactivated = true;return reply
            }
            for _ in 0..<20 { await Task.yield() }
            check("native action shares pending executor with lifecycle modification", !deactivated && f.bindings.manager.instance(for:f.target.identifier) === instance && initialController.owner.isActive)
            await gate.finish();_ = try await first.value;let state = try await next.value
            check("native deactivation waits for action reply and removes same canonical instance", deactivated && !state.active && f.bindings.manager.instance(for:f.target.identifier) == nil)
            _ = try await f.lifecycle.start(f.target,requestedIdentifier:"owned alias",sender:nil)
        }
        f.bindings.manager.markStoppedByUser(for:f.target.identifier);effects = [];var stopped = false
        do { _ = try await f.lifecycle.performAction(f.target,requestedIdentifier:"owned stopped alias",sender:nil,action:.type("owned"),requestEnvironment:env) }
        catch ControllerInstanceResolutionError.stoppedByUser(let alias) { stopped = alias == "owned stopped alias" }
        check("native stopped request fails before any focus/cursor/delivery effect", stopped && effects.isEmpty)
        f.bindings.manager.clearStoppedByUser(for:f.target.identifier)
        await f.finish()
        await MainActor.run { initialController.deactivate(); replacement?.deactivate() }
    }
}
