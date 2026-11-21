import AppKit
import ApplicationServices

@main
struct EventStreamNativeContextTests {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ label: String, _ result: @autoclosure () -> Bool) {
        if result() { checks += 1; print("PASS: \(label)") }
        else { failures += 1; print("FAIL: \(label)") }
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--fixture") { fixture(); return }
        let status = try run()
        if status != 0 { exit(status) }
    }
    @MainActor static func fixture() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=NSWindow(contentRect:.init(x:100,y:100,width:260,height:140),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="Disposable EventStream Context Fixture";window.isReleasedWhenClosed=false
        let label=NSTextField(labelWithString:"Context Label")
        label.frame = .init(x:20,y:40,width:180,height:24)
        label.setAccessibilityIdentifier("native-context-label")
        window.contentView!.addSubview(label)
        window.orderBack(nil);app.finishLaunching()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            let data=try! JSONSerialization.data(withJSONObject:["pid":getpid(),"windowID":window.windowNumber])
            FileHandle.standardOutput.write(data+Data([10]))
        }
        withExtendedLifetime(window) { app.run() }
    }
    @MainActor static func run() throws -> Int32 {
        guard AXIsProcessTrusted(),
              (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            fputs("Native context fixture requires an unlocked macOS session and Accessibility.\n", stderr)
            return 2
        }
        // Another process keeps its main run loop free to serve AX queries.
        let child=Process(),pipe=Pipe()
        child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--fixture"]
        child.standardOutput=pipe;child.standardError=FileHandle.standardError
        try child.run()
        let watchdog=DispatchWorkItem { if child.isRunning {child.terminate()} }
        DispatchQueue.global().asyncAfter(deadline:.now()+15,execute:watchdog)
        defer { watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit() }
        let data=pipe.fileHandleForReading.availableData
        let ready=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let pid=(ready["pid"] as! NSNumber).int32Value,id=(ready["windowID"] as! NSNumber).uint32Value
        let backend=EventStreamNativeContextBackend(),raw=backend.window(id)
        let cgRows=CGWindowListCopyWindowInfo(.optionIncludingWindow,id) as? [[String:Any]] ?? []
        let cgRow=cgRows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
        let cgBounds=cgRow?[kCGWindowBounds as String] as? [String:Any]
        let cgFrame=cgBounds.flatMap { CGRect(dictionaryRepresentation:$0 as CFDictionary) }
        check("native CGWindow lookup resolves disposable window identity", raw?.id == id && raw?.processIdentifier == pid)
        check("native CGWindow frame matches actual WindowServer metadata", raw?.frame == cgFrame && cgFrame?.isEmpty == false)
        check("matching list filters service-owned and high-level windows", backend.matchingWindows().allSatisfy { $0.processIdentifier != getpid() && $0.level < Int(CGWindowLevelForKey(.mainMenuWindow)) })
        check("nonexistent CGWindow ID is unavailable", backend.window(UInt32.max) == nil)
        let node=backend.application(pid)
        check("native AX PID query resolves application root", backend.processIdentifier(node) == pid)
        let role=backend.string(node,"AXRole")
        print("FIXTURE ROOT: role=\(String(describing:role)) trusted=\(AXIsProcessTrusted())")
        check("native role query resolves application root", role == "AXApplication")
        check("typed native node reader rejects scalar role attribute", backend.node(node,"AXRole") == nil && backend.nodes(node,"AXRole").isEmpty)
        check("native app snapshot preserves process identity", backend.snapshot(pid,fallbackName:"Context fixture")?.processIdentifier == pid)
        let windows=backend.nodes(node,"AXWindows")
        let fixtureWindow=windows.first { backend.windowID($0) == id }
        print("FIXTURE AX WINDOWS: count=\(windows.count) roles=\(windows.map { backend.string($0,"AXRole") ?? "nil" })")
        check("native AX window enumeration locates disposable window", fixtureWindow != nil)
        let resolver=EventStreamContextResolver(backend:backend)
        check("native context resolves disposable window metadata", resolver.resolve(.init(processIdentifier:pid,windowID:id)).window?.title == "Disposable EventStream Context Fixture")
        let selected = try resolver.captureContext(.init(identity:.init(windowID:id)))
        check("native capture context selects explicit window without event PID", selected.nativeWindow.id == id && backend.processIdentifier(selected.application) == pid)
        check("native explicit-window context has no borrowed focused element", selected.focusedElement == nil)
        check("native capture context resolves the actual window AX reference", backend.windowID(selected.window) == id)
        let conflicting = try resolver.captureContext(.init(identity:.init(processIdentifier:getpid(),windowID:id)))
        check("native capture window owner precedes conflicting target PID", conflicting.nativeWindow.processIdentifier == pid)
        let captured = resolver.resolve(.init(processIdentifier:pid,windowID:id))
        let textContext = resolver.textContext(captured)
        check("native text flush keeps captured application/window metadata", textContext.0 == captured.app && textContext.1 == captured.window)
        var queue=fixtureWindow.map { [$0] } ?? [],index=0,found:EventStreamAXNode?
        while index<queue.count && index<64 {
            let current=queue[index];index += 1
            if backend.string(current,"AXIdentifier") == "native-context-label" { found=current;break }
            let children=backend.nodes(current,"AXChildren")
            queue.append(contentsOf:children.prefix(max(0,64-queue.count)))
        }
        check("native AX descriptor reads disposable static label", found.map { backend.describe($0).role == "AXStaticText" && backend.describe($0).title == "Context Label" } == true)
        let context=EventStreamNativeContext()
        var requests=0
        let builder=context.makeInputBuilder(nextIdentity:{fatalError("Inactive capture must not allocate")},isRecording:{false},fallbackProcessIdentifier:{nil},shouldCaptureApplication:{_ in requests += 1;return false},resolveTextContext:{($0?.app,$0?.window)},emitText:{_ in fatalError("Unexpected text")},prepare:{_ in fatalError("Unexpected interaction")})
        check("native context providers construct an idle builder without installing capture", builder.pendingInteractionCount == 0 && requests == 0)
        var records: [EventStreamRecord] = [], sequence = 0
        let textBuilder = context.makeInputBuilder(nextIdentity: { sequence += 1; return .init(id:sequence,timestamp:Date()) },
            isRecording:{true},fallbackProcessIdentifier:{nil},shouldCaptureApplication:{$0.processIdentifier == pid},
            emitText:{records.append($0)},prepare:{_ in fatalError("Text fixture does not capture AX records")})
        textBuilder.receive(.init(type:.keyDown,location:.zero,flags:[],target:.init(processIdentifier:pid,windowID:id),
            clickCount:0,keyCode:0,characters:"nativo",charactersIgnoringModifiers:"nativo"))
        textBuilder.flushText();textBuilder.discardPendingInput()
        check("native default text resolver emits retained context through builder", records.count == 1 && records[0].keyboard?.text == "nativo" && records[0].app?.processIdentifier == pid && records[0].window?.windowID == id)
        print("EVENT STREAM NATIVE CONTEXT: \(checks) checks passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

