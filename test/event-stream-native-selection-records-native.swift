import AppKit
import ApplicationServices

private final class SelectionRecordsFixturePanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

@MainActor private final class SelectionTableData:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    func numberOfRows(in tableView:NSTableView)->Int {20}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let label=NSTextField(labelWithString:"selection row \(row)")
        label.setAccessibilityIdentifier("selection-cell-\(row)");return label
    }
}

@main enum NativeSelectionRecordTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ result:Bool) {
        precondition(result,"FAIL: \(label)");checks += 1;print("PASS: \(label)")
    }
    @MainActor static func fixture() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=SelectionRecordsFixturePanel(contentRect:.init(x:120,y:120,width:700,height:430),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
        window.hidesOnDeactivate=false
        window.title="Disposable Native Selection Records";window.isReleasedWhenClosed=false
        let textScroll=NSScrollView(frame:.init(x:15,y:15,width:300,height:395))
        let text=NSTextView(frame:.init(x:0,y:0,width:300,height:395));text.isRichText=false
        text.string="first 😀 café third";text.setAccessibilityIdentifier("native-selection-text")
        textScroll.documentView=text;window.contentView!.addSubview(textScroll)
        let tableScroll=NSScrollView(frame:.init(x:335,y:15,width:345,height:395))
        let table=NSTableView(),data=SelectionTableData()
        let column=NSTableColumn(identifier:.init("name"));column.width=320;table.addTableColumn(column)
        table.headerView=nil;table.rowHeight=17;table.allowsMultipleSelection=true
        table.setAccessibilityIdentifier("native-selection-table");table.dataSource=data;table.delegate=data
        tableScroll.documentView=table;window.contentView!.addSubview(tableScroll);table.reloadData()
        window.orderBack(nil);window.makeFirstResponder(text);app.finishLaunching()
        func report(_ value:[String:Any]) {
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:value)+Data([10]))
        }
        var commandBuffer=""
        FileHandle.standardInput.readabilityHandler={handle in
            let bytes=handle.availableData
            guard !bytes.isEmpty else {handle.readabilityHandler=nil;return}
            DispatchQueue.main.async {
                commandBuffer += String(decoding:bytes,as:UTF8.self)
                while let end=commandBuffer.firstIndex(of:"\n") {
                    let command=String(commandBuffer[..<end]);commandBuffer.removeSubrange(...end)
                    if command=="clear" {text.setSelectedRange(.init(location:0,length:0))}
                    if command=="first" {text.setSelectedRange(.init(location:0,length:5))}
                    report(["command":command])
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            text.setSelectedRange(.init(location:6,length:7))
            table.selectRowIndexes(IndexSet(integersIn:0..<15),byExtendingSelection:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {report(["pid":getpid(),"window":window.windowNumber,"isKeyWindow":window.isKeyWindow,"textIsFirstResponder":window.firstResponder === text])}
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+45) {app.terminate(nil)}
        withExtendedLifetime((window,text,table,data)) {app.run()}
    }
    static func line(_ handle:FileHandle)throws->[String:Any] {
        var data=Data()
        while let next=try handle.read(upToCount:1),!next.isEmpty {
            if next[0]==10 {return try JSONSerialization.jsonObject(with:data) as! [String:Any]}
            data.append(next)
        }
        throw NSError(domain:"NativeSelectionFixtureEnded",code:1)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--fixture") {fixture();return}
        let trusted=AXIsProcessTrusted()
        let locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        guard trusted,!locked else {
            fputs("Native selection records require unlocked macOS and Accessibility: accessibility=\(trusted), locked=\(locked).\n",stderr);exit(2)
        }
        let child=Process(),output=Pipe(),input=Pipe()
        child.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--fixture"]
        child.standardInput=input;child.standardOutput=output;child.standardError=FileHandle.standardError;try child.run()
        let watchdog=DispatchWorkItem {if child.isRunning {child.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+35,execute:watchdog)
        defer {watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit()}
        let ready=try line(output.fileHandleForReading)
        check("native selection fixture retains logical focus without receiving keyboard focus",ready["isKeyWindow"] as? Bool == false && ready["textIsFirstResponder"] as? Bool == true)
        let pid=(ready["pid"] as! NSNumber).int32Value,id=(ready["window"] as! NSNumber).uint32Value
        let app=AXUIElementCreateApplication(pid)
        func raw(_ element:AXUIElement,_ name:String)->AnyObject? {
            var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
        }
        func refs(_ value:AnyObject?)->[AXUIElement] {
            (value as? [AnyObject] ?? []).compactMap {CFGetTypeID($0)==AXUIElementGetTypeID() ? unsafeBitCast($0,to:AXUIElement.self):nil}
        }
        var pending=refs(raw(app,"AXWindows")),index=0,text:AXUIElement?,table:AXUIElement?
        while index<pending.count && index<400 {
            let element=pending[index];index += 1
            let identifier=raw(element,"AXIdentifier") as? String
            if identifier=="native-selection-text" {text=element}
            if identifier=="native-selection-table" {table=element}
            pending.append(contentsOf:refs(raw(element,"AXChildren")))
        }
        guard let text,let table else {throw NSError(domain:"NativeSelectionFixtureMissing",code:1)}
        check("external fixture exposes real text and table AX sources",raw(text,"AXRole") as? String == "AXTextArea" && raw(table,"AXRole") as? String == "AXTable")
        let textNode=EventStreamAXNode(text),tableNode=EventStreamAXNode(table)
        let native=EventStreamNativeSelectionRecordBackend()
        check("native selected range uses UTF16 location and length",native.selectedRange(textNode) == .init(location:6,length:7))
        check("native selected text preserves emoji and accented text",native.selectedText(textNode)=="😀 café")
        let selected=try native.selectedItems(tableNode,attribute:"AXSelectedRows",maximum:12)
        check("fresh native selected rows obey maximum12",selected?.count==12)
        check("native selected rows preserve external process identity",selected?.allSatisfy {node in var owner:pid_t = -1;return AXUIElementGetPid(node.element,&owner) == .success && owner==pid}==true)
        let context=EventStreamNativeContext()
        let url=URL(string:"https://selection.fixture/captured")!;context.resolver.recordCapturedURL(url,for:id)
        var sequence=0
        let builder=context.makeSelectionRecordBuilder(nextIdentity:{sequence += 1;return .init(id:sequence,timestamp:Date())})
        let initial=builder.make(element:textNode,notification:"AXSelectedTextChanged")!
        check("concrete native factory captures text selection without injected descriptions",initial.record.selection?.selectedText=="😀 café" && initial.record.selection?.target?.role=="AXTextArea")
        check("concrete native factory attributes application and window",initial.record.app?.processIdentifier==pid && initial.record.window?.windowID==id && initial.record.window?.title=="Disposable Native Selection Records")
        check("native containing-window metadata retains previously captured URL",initial.record.window?.url==url.absoluteString)
        check("native factory supplies the reflected notification description",initial.key.contains("AXNotification(name: AXSelectedTextChanged)") && !initial.key.contains("native-selection-text"))
        let rows=builder.make(element:tableNode,notification:"AXSelectedRowsChanged")!
        check("native selection builder projects actual selected row descriptions",rows.record.selection?.selectedItems.count==12 && rows.record.selection?.selectedItems.first?.title?.contains("selection row 0")==true)
        check("native item key contains actual target identifier",rows.key.contains("native-selection-table") && rows.key.contains("AXNotification(name: AXSelectedRowsChanged)"))
        var callbackSequence=100
        let callbackFactory=EventStreamNativeSelectionRecordFactory(nextIdentity:{callbackSequence += 1;return .init(id:callbackSequence,timestamp:Date())})
        callbackFactory.context.resolver.recordCapturedURL(url,for:id)
        let capturedRows=callbackFactory.make(element:table,notification:"AXSelectedRowsChanged")!
        check("actual callback constructor retains15 cached selected rows above fresh max12",capturedRows.record.selection?.selectedItems.count==15 && capturedRows.record.selection?.selectedItems.last?.title?.contains("selection row 14")==true)
        let capturedText=callbackFactory.make(element:text,notification:"AXSelectedTextChanged")!
        check("actual callback snapshots share native app window URL and text context",capturedText.record.app?.processIdentifier==pid && capturedText.record.window?.windowID==id && capturedText.record.window?.url==url.absoluteString && capturedText.record.selection?.selectedText=="😀 café" && capturedText.record.id==102)
        try input.fileHandleForWriting.write(contentsOf:Data("clear\n".utf8));_=try line(output.fileHandleForReading)
        let cleared=builder.make(element:textNode,notification:"AXSelectedTextChanged")
        check("empty native selection suppresses record without consuming identity",cleared==nil && sequence==2)
        try input.fileHandleForWriting.write(contentsOf:Data("first\n".utf8));_=try line(output.fileHandleForReading)
        let latest=builder.make(element:textNode,notification:"AXSelectedTextChanged")!
        check("same source observes later native selection without stale range or text",latest.record.selection?.selectedText=="first" && latest.record.selection?.selectedRange == .init(location:0,length:5) && latest.record.id==3)
        check("native text selection retains grouping key across changed range",latest.key==initial.key)
        var delivered:[EventStreamRecord]=[]
        let queue=EventStreamAXNotificationQueue(isRecording:{true},emit:{delivered.append($0)})
        queue.enqueue(initial.record,key:initial.key,notification:initial.notification)
        queue.enqueue(latest.record,key:latest.key,notification:latest.notification)
        queue.flushPendingRecords()
        check("native records compose with queue preserving latest captured payload",delivered==[latest.record] && queue.pendingCount==0 && queue.scheduledCount==0)
        queue.cancelPendingRecords()
        for _ in 0..<20 {await Task.yield()}
        print("\(checks) checks")
    }
}
