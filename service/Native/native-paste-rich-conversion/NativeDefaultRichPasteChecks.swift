import AppKit
import Foundation

@MainActor enum NativeDefaultRichPasteChecks {
    static func run(output: URL,fixture: URL,directory: URL) async throws -> Int32 {
        var cases: [[String:Any]] = []
        var observedTypes: [[String:Any]] = []
        func check(_ name: String,_ value: Bool) { cases.append(["name":name,"passed":value]); if !value { print("FAIL: "+name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let child = Process(); child.executableURL = fixture; child.arguments = ["--paste-observation-fixture",directory.path]
        try child.run(); defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) { try await Task.sleep(for:.milliseconds(5)) }
        guard child.isRunning,FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready").path) else { return 2 }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.clearContents(); _ = board.setString("owned baseline",forType:.string)
        let ledger = OwnedPasteLedger()
        let samples: [(ControllerPasteFormat,String,String)] = [(.text,"**literal** 😀","**literal** 😀"),(.markdown,"**bold** and café 😀","bold and café 😀\n"),(.html,"<p><b>bold</b> and café 😀</p>","bold and café 😀\n")]
        for (format,source,expected) in samples {
            let backend = OwnedPasteBackend(board:board,pid:child.processIdentifier,directory:directory,mode:.richRead,label:source,ledger:ledger)
            try await ControllerGlobalPasteQueue.shared.sync { try await ControllerPasteEngine(backend:backend).paste(text:source,format:format) }
            let representations = backend.receivedRepresentations
            let types: Set<String> = format == .text ? ["public.utf8-plain-text"]:["public.html","public.rtf","public.utf8-plain-text"]
            observedTypes.append(["format":String(describing:format),"types":representations.keys.sorted()])
            //AppKit can synthesize an extra UTF16 flavor for a rich item.
            //Every explicitly supplied representation must still be exact.
            check("default \(format) engine supplies actual native promised representations",Set(representations.keys).isSuperset(of:types) && representations["public.utf8-plain-text"] == Data(expected.utf8))
            if format != .text {
                let alias = representations["public.utf16-external-plain-text"]
                check("default \(format) native UTF16 alias preserves text when advertised",alias.map { String(data:$0,encoding:.utf16) == expected } ?? true)
            }
            check("default \(format) engine correlates all successful reads with native AX notification",backend.observation?.state.snapshot.reads.count == types.count && backend.observation?.state.snapshot.reads.allSatisfy { $0.succeeded } == true && backend.observation?.state.snapshot.quietDeadline != nil)
            check("default \(format) engine restores clipboard and stops observation",backend.restored == 1 && backend.flag && backend.events.last == "stop" && board.string(forType:.string) == "owned baseline")
            if let data = representations["public.rtf"] {
                let decoded = try NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
                check("default \(format) receiver gets decodable native RTF",decoded.string == expected)
            }
        }
        try "stop".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        for _ in 0..<200 where child.isRunning { try await Task.sleep(for:.milliseconds(5)) }
        check("default rich-paste owned fixture exits without foreground change",!child.isRunning && foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier && ledger.active == 0 && ledger.maximum == 1)
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases,"observed_native_types":observedTypes,"actual_native_default_text_markdown_HTML_and_RTF_clipboard_engine":true,"native_AX_notifications_received":true,"physical_send_and_focus_intercepted":true,"general_clipboard_transaction_executed":false,"target_terminal":!child.isRunning,"full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native default rich paste: \(cases.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
        return passed ? 0:3
    }
}
