import Foundation
import AppKit
import ApplicationServices

@main enum NativeProducerTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ value:Bool) {
        guard value else {print("FAIL: \(label)");fatalError(label)}
        checks += 1;print("PASS: \(label)")
    }
    @MainActor static func pump() {_ = RunLoop.main.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))}
    @MainActor static func until(_ label:String,_ condition:()->Bool) async throws {
        let deadline=ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now<deadline else {throw NSError(domain:"NativeProducerFixture",code:1,userInfo:[NSLocalizedDescriptionKey:label])}
            pump();try await Task.sleep(for:.milliseconds(15))
        }
    }
    static func events(_ directory:URL)->[[String:Any]] {
        guard let text=try? String(contentsOf:directory.appendingPathComponent("events.jsonl"),encoding:.utf8) else {return []}
        return text.split(separator:"\n").compactMap {try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
    }
    @MainActor static func command(_ value:String,directory:URL,response:String) async throws->[String:Any] {
        let count=events(directory).count
        try value.write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        var result:[String:Any]?
        try await until("No owned fixture response for \(value)") {
            result=events(directory).dropFirst(count).first {$0["event"] as? String==response};return result != nil
        }
        return result!
    }
    static func raw(_ element:AXUIElement,_ name:String)->AnyObject? {
        var result:CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success ? result:nil
    }
    static func editor(_ app:AXUIElement)->AXUIElement? {
        var queue:[AXUIElement]=[app],index=0
        while index<queue.count && index<400 {
            let node=queue[index];index += 1
            if raw(node,"AXIdentifier") as? String=="input-editor" {return node}
            for value in raw(node,"AXChildren") as? [AnyObject] ?? [] where CFGetTypeID(value)==AXUIElementGetTypeID() {
                queue.append(unsafeBitCast(value,to:AXUIElement.self))
            }
        }
        return nil
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _=NSApplication.shared.setActivationPolicy(.prohibited)
        let locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        guard !locked,AXIsProcessTrusted(),CGPreflightScreenCaptureAccess() else {
            fputs("Native producer fixture requires unlocked macOS, Accessibility and screen recording.\n",stderr);exit(2)
        }
        if CommandLine.arguments.contains("--preflight") {print("Native producer session preflight ready");return}
        let arguments=CommandLine.arguments
        guard arguments.count==4,let pid=Int32(arguments[1]),let windowID=UInt32(arguments[2]),
              let owned=NSRunningApplication(processIdentifier:pid),owned.bundleIdentifier=="test.acua.event-stream-producer-fixture" else {
            fatalError("Only the owned disposable native-producer fixture is accepted")
        }
        let directory=URL(fileURLWithPath:arguments[3])
        _=owned.activate(options:[])
        _=try await command("request-key-focus",directory:directory,response:"requested-key-focus")
        try await until("Owned fixture did not become foreground/menu owner") {
            pump();return NSWorkspace.shared.frontmostApplication?.processIdentifier==pid && NSWorkspace.shared.menuBarOwningApplication?.processIdentifier==pid
        }
        let before=try await command("state",directory:directory,response:"state")
        check("owned native producer fixture is active before recording",before["isActive"] as? Bool==true && before["frontmostPID"] as? Int32==pid)
        guard let text=editor(AXUIElementCreateApplication(pid)) else {fatalError("Owned fixture editor not found")}
        check("owned editor exposes real text area accessibility",raw(text,"AXRole") as? String=="AXTextArea")
        let recorder=EventStreamNativeRecorderFactory.make(prefetchConfiguration:{[:]})
        recorder.shouldCaptureApplication={$0.processIdentifier==pid}
        var records:[EventStreamRecord]=[],suppressed:[EventStreamRecord]=[]
        recorder.onRecordStored={records.append($0)};recorder.onSuppressedRecordStored={suppressed.append($0)}
        defer {recorder.stop(emitSessionEnded:false)}
        try recorder.start()
        check("default native producer starts and emits session boundary",recorder.isRecording && records.first?.kind == .sessionStarted && records.first?.id==1)
        try await until("Default native producer did not capture owned AX window") {
            records.contains {$0.kind == .windowChanged && $0.app?.processIdentifier==pid && $0.window?.windowID==windowID && $0.ax?.text.isEmpty==false}
        }
        let initial=records.first {$0.kind == .windowChanged && $0.ax != nil}!
        check("default native capture uses owned process and window metadata",initial.app?.processIdentifier==pid && initial.window?.windowID==windowID)
        check("initial native tree capture is full and nonempty",initial.ax?.mode == .fullTree && initial.ax?.text.isEmpty==false)
        let started=records.filter{$0.kind == .sessionStarted}.count;try recorder.start()
        check("repeated default native start creates no duplicate session boundary",records.filter{$0.kind == .sessionStarted}.count==started)
        var selection=CFRange(location:0,length:2)
        check("owned AX selection update succeeds",AXUIElementSetAttributeValue(text,"AXSelectedTextRange" as CFString,AXValueCreate(.cfRange,&selection)!) == .success)
        try await until("Native observer did not deliver owned text selection") {
            records.contains {$0.kind == .selectionChanged && $0.selection?.selectedRange == .init(location:0,length:2)}
        }
        let selected=records.last {$0.kind == .selectionChanged}!
        check("native observer captures exact selected Unicode",selected.selection?.selectedText=="🙂" && selected.selection?.target?.role=="AXTextArea")
        check("native observer attributes selection to owned window",selected.app?.processIdentifier==pid && selected.window?.windowID==windowID)
        selection=CFRange(location:0,length:0)
        check("owned insertion point reset succeeds",AXUIElementSetAttributeValue(text,"AXSelectedTextRange" as CFString,AXValueCreate(.cfRange,&selection)!) == .success)
        let inputBefore=records.filter{$0.kind == .keyboardTextInput}.count
        _=try await command("event-stream-text",directory:directory,response:"event-stream-text-posted")
        try await until("Default native tap did not record owned Unicode input") {records.filter{$0.kind == .keyboardTextInput}.count==inputBefore+1}
        let typed=records.last {$0.kind == .keyboardTextInput}!,after=try await command("state",directory:directory,response:"state")
        check("native listen-only source preserves fixture insertion",(after["text"] as? String)?.replacingOccurrences(of:"á😀",with:"")==before["text"] as? String && after["text"] as? String != before["text"] as? String)
        check("default composed native text payload retains exact characters",typed.keyboard?.text=="á😀" && typed.keyboard?.target?.role=="AXTextArea")
        check("default composed native text retains owned context",typed.app?.processIdentifier==pid && typed.window?.windowID==windowID)
        check("native records have unique shared identities",Set(records.map(\.id)).count==records.count && recorder.sequence >= typed.id)
        recorder.stop(emitSessionEnded:true)
        check("default native stop emits end boundary and clears recording state",!recorder.isRecording && records.last?.kind == .sessionEnded)
        let typedAtStop=records.filter{$0.kind == .keyboardTextInput}.count
        _=try await command("event-stream-text",directory:directory,response:"event-stream-text-posted")
        try await Task.sleep(for:.milliseconds(1000));pump()
        check("stopped native tap adds no new typed record",records.filter{$0.kind == .keyboardTextInput}.count==typedAtStop)
        let sequenceAtStop=recorder.sequence,countAtStop=records.count
        try recorder.start()
        try await until("Restarted native recorder did not capture owned window") {
            records.dropFirst(countAtStop).contains {$0.kind == .windowChanged && $0.app?.processIdentifier==pid && $0.ax?.mode == .fullTree}
        }
        check("default native restart continues global sequence",records.dropFirst(countAtStop).first?.id==sequenceAtStop+1 && records.filter{$0.kind == .sessionStarted}.count==2)
        check("default native restart clears predecessor for full capture",records.dropFirst(countAtStop).contains {$0.kind == .windowChanged && $0.ax?.mode == .fullTree})
        check("all useful native AX captures stay in owned fixture",records.filter{$0.ax != nil}.allSatisfy{$0.app?.processIdentifier==pid && $0.window?.windowID==windowID})
        recorder.stop(emitSessionEnded:false)
        print("\(checks) checks")
    }
}
